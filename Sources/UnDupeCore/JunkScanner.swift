import Foundation

/// One removable junk item (a cache folder, a log, a derived-data tree…).
public struct JunkItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let sizeBytes: Int64
}

/// A named group of junk items with a one-line explanation of why it's safe.
public struct JunkCategory: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let explanation: String
    public let items: [JunkItem]
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
}

/// Finds regenerable junk under a **strict allowlist** of user-domain roots — never
/// a free-form scan. Everything it reports lives in `~/Library/...`, so it's always
/// `ProtectedPaths.isDeletable` and removal goes to the Trash (recoverable). The
/// allowlist is deliberately conservative: caches, logs, and developer leftovers
/// that apps rebuild on demand.
public enum JunkScanner {

    /// A candidate path with a display name, before sizing.
    private struct Candidate { let name: String; let path: String }

    private struct Group {
        let name: String
        let explanation: String
        let candidates: [Candidate]
    }

    // MARK: - Scan

    public static func scan() -> [JunkCategory] {
        let home = NSHomeDirectory()
        let groups: [Group] = [
            Group(
                name: "User Caches",
                explanation: "Reusable app caches. Safe to clear — apps rebuild them as needed.",
                candidates: children(of: "\(home)/Library/Caches")
            ),
            Group(
                name: "Logs",
                explanation: "Diagnostic logs from apps and the system. Safe to remove.",
                candidates: children(of: "\(home)/Library/Logs")
            ),
            Group(
                name: "Xcode & Developer",
                explanation: "Derived data, archives, and device support — large and regenerable.",
                candidates: existing([
                    Candidate(name: "Derived Data", path: "\(home)/Library/Developer/Xcode/DerivedData"),
                    Candidate(name: "Archives", path: "\(home)/Library/Developer/Xcode/Archives"),
                    Candidate(name: "iOS DeviceSupport", path: "\(home)/Library/Developer/Xcode/iOS DeviceSupport"),
                    Candidate(name: "Simulator Caches", path: "\(home)/Library/Developer/CoreSimulator/Caches"),
                ])
            ),
        ]

        // Size every candidate in parallel (cache trees can be large).
        let allPaths = groups.flatMap { $0.candidates.map(\.path) }
        let sizes = FileSizing.parallelSizes(allPaths)

        return groups.compactMap { group in
            let items = group.candidates
                .compactMap { candidate -> JunkItem? in
                    let size = sizes[candidate.path] ?? 0
                    guard size > 0, ProtectedPaths.isDeletable(candidate.path) else { return nil }
                    return JunkItem(name: candidate.name, path: candidate.path, sizeBytes: size)
                }
                .sorted { $0.sizeBytes > $1.sizeBytes }
            guard !items.isEmpty else { return nil }
            return JunkCategory(name: group.name, explanation: group.explanation, items: items)
        }
    }

    // MARK: - Remove

    /// Removes the given junk items via SafeDelete. By default they go to the
    /// Trash (recoverable); pass `permanently: true` to skip the Trash and delete
    /// outright (still gated by `ProtectedPaths`). The permanent path is opt-in,
    /// chosen by the user in the Automatic Cleanup sheet.
    public static func remove(_ items: [JunkItem], permanently: Bool = false) -> [TrashResult] {
        let targets = items.map { SafeDelete.TrashTarget(path: $0.path, size: $0.sizeBytes) }
        return permanently ? SafeDelete.deletePermanently(targets) : SafeDelete.moveToTrash(targets)
    }

    // MARK: - Candidate building

    private static func children(of dir: String) -> [Candidate] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return entries
            .filter { !$0.hasPrefix(".") }
            .map { Candidate(name: $0, path: "\(dir)/\($0)") }
    }

    private static func existing(_ candidates: [Candidate]) -> [Candidate] {
        candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
