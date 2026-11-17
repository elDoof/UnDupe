import Foundation

/// Runs a system tool (`launchctl`, `pluginkit`, `hdiutil`) and collects what it
/// printed.
///
/// One place for this rather than three, because the details are easy to get
/// subtly wrong and the failure mode is a hang:
///
/// - **stderr goes to the null device.** A `Pipe` nobody reads fills up at 64 KB
///   and blocks the child forever.
/// - **stdin is the null device**, so a tool that decides to prompt gets
///   end-of-file instead of waiting on a terminal that isn't there.
/// - **There is a deadline.** These calls sit behind spinners in the UI; a tool
///   that never returns must not leave one spinning indefinitely.
public enum ProcessRunner {

    /// What a finished tool reported.
    public struct Output: Sendable {
        /// The tool's exit status. Zero conventionally means success.
        public let status: Int32
        /// Everything the tool wrote to standard output.
        public let data: Data

        public var isSuccess: Bool { status == 0 }
        /// Standard output decoded as UTF-8, or `nil` if it wasn't text.
        public var text: String? { String(data: data, encoding: .utf8) }
    }

    /// Generous for tools that normally answer in milliseconds.
    public static let defaultTimeout: TimeInterval = 30

    /// How long to wait for a terminated tool to actually exit and for its
    /// output pipe to close before giving up on both.
    private static let terminationGrace: TimeInterval = 2

    /// Runs `executable` with `arguments` and waits for it to finish.
    ///
    /// - Returns: the tool's exit status and output, or `nil` if it could not be
    ///   launched or did not finish within `timeout` (in which case it is
    ///   terminated).
    public static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout concurrently: a tool that prints more than the pipe
        // buffer holds would otherwise block on write and never exit.
        let collector = OutputCollector()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            collector.store(stdout.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = exited.wait(timeout: .now() + terminationGrace)
            return nil
        }
        // The tool has exited, so the pipe closes as soon as nothing it spawned
        // still holds the write end; don't wait forever on a stray grandchild.
        _ = drained.wait(timeout: .now() + terminationGrace)

        return Output(status: process.terminationStatus, data: collector.value)
    }

    /// Hands the collected output from the reader queue back to the caller.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func store(_ newValue: Data) {
            lock.lock(); data = newValue; lock.unlock()
        }

        var value: Data {
            lock.lock(); defer { lock.unlock() }; return data
        }
    }
}
