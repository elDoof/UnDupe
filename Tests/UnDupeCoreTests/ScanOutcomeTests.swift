import XCTest
@testable import UnDupeCore

/// A scan that returns no tree has three very different meanings. Conflating
/// them is what let an unreadable root render as a valid, empty disk.
final class ScanOutcomeTests: XCTestCase {

    func testReportsAMissingPathRatherThanAnEmptyTree() {
        let missing = NSTemporaryDirectory() + "/undupe-does-not-exist-\(UUID().uuidString)"
        guard case .failed(.pathNotFound) = ScanEngine().scan(rootPath: missing, progress: { _ in }) else {
            return XCTFail("a missing path should fail, not scan")
        }
    }

    func testReportsAFileAsNotADirectory() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("undupe-file-\(UUID().uuidString).bin")
        try Data(count: 16).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }

        guard case .failed(.notADirectory) = ScanEngine().scan(rootPath: file.path, progress: { _ in }) else {
            return XCTFail("a regular file should be refused")
        }
    }

    func testReportsAnUnreadableDirectoryInsteadOfScanningItAsEmpty() throws {
        // The regression this whole type exists for: the directory reader returns
        // an empty array when open(2) is denied, which is indistinguishable from
        // a genuinely empty folder unless the engine checks access up front.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("undupe-locked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: directory.appendingPathComponent("hidden.bin"))
        // Strip every read permission.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        guard case .failed(.unreadable) = ScanEngine().scan(rootPath: directory.path, progress: { _ in }) else {
            return XCTFail("an unreadable directory must not scan as empty")
        }
    }

    func testScansAReadableDirectory() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("undupe-ok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: 2_048).write(to: directory.appendingPathComponent("a.bin"))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let outcome = ScanEngine().scan(rootPath: directory.path, progress: { _ in })
        let tree = try XCTUnwrap(outcome.tree, "a readable directory should scan")
        XCTAssertGreaterThan(tree.size, 0)
        XCTAssertEqual(tree.fileCount, 1)
    }

    func testCountsAnUnreadableSubfolderInsteadOfSilentlyShowingItEmpty() throws {
        // Arrange: one readable folder, one the scanner is denied.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UnDupeSkippedTests-\(UUID().uuidString)")
        let open = root.appendingPathComponent("open")
        let locked = root.appendingPathComponent("locked")
        for folder in [open, locked] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 0x55, count: 4_096)
                .write(to: folder.appendingPathComponent("file.bin"))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        try XCTSkipIf(getuid() == 0, "root ignores permission bits, so nothing is unreadable")

        // Act
        let engine = ScanEngine()
        let outcome = engine.scan(rootPath: root.path) { _ in }

        // Assert
        let tree = try XCTUnwrap(outcome.tree)
        XCTAssertEqual(engine.skippedDirectoryCount, 1)
        XCTAssertEqual(tree.fileCount, 1, "only the readable folder's file should be counted")
        XCTAssertNotNil(tree.children.first { $0.name == "locked" },
                        "the unreadable folder should still appear in the tree")
    }

    func testAFullyReadableScanSkipsNothing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UnDupeSkippedTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let engine = ScanEngine()
        _ = engine.scan(rootPath: root.path) { _ in }

        XCTAssertEqual(engine.skippedDirectoryCount, 0)
    }

    func testEveryFailureExplainsItselfToTheUser() {
        for failure in [ScanFailure.pathNotFound, .notADirectory, .unreadable] {
            XCTAssertFalse(failure.message.isEmpty)
        }
    }

    /// `scan` clears the cancel flag on entry, so `cancel()` only has an effect
    /// while a scan is actually running. Pinning that down because the opposite
    /// is easy to assume: a stale cancel from a previous scan must not silently
    /// kill the next one.
    func testAStaleCancelDoesNotAbortTheNextScan() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("undupe-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: 1_024).write(to: directory.appendingPathComponent("a.bin"))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let engine = ScanEngine()
        engine.cancel()
        XCTAssertNotNil(engine.scan(rootPath: directory.path, progress: { _ in }).tree)
    }
}
