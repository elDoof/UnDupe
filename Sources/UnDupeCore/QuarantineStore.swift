import Foundation

/// A reversible "disable" store. Instead of deleting a startup item (or other
/// togglable system item), UnDupe moves the backing file out of the way into its
/// own Application Support folder and records it in a manifest, so the exact same
/// file can be restored later. This keeps "disable" non-destructive and undoable
/// without involving the Trash.
///
/// Manifest: `~/Library/Application Support/UnDupe/Disabled/manifest.json`,
/// an array of `Item` records (ISO-8601 dates).
public enum QuarantineStore {

    /// One quarantined (disabled) item.
    public struct Item: Codable, Identifiable, Hashable, Sendable {
        public var id: String { originalPath }
        /// Where the file lived before it was disabled (where it returns on restore).
        public let originalPath: String
        /// Where the file now sits inside the quarantine folder.
        public let quarantinedPath: String
        /// A caller-defined bucket (e.g. "userAgent") — also the subfolder name.
        public let kind: String
        public let disabledAt: Date
    }

    // MARK: - Locations

    private static var baseDir: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("UnDupe/Disabled", isDirectory: true)
    }

    private static var manifestURL: URL {
        baseDir.appendingPathComponent("manifest.json")
    }

    // MARK: - Operations

    /// Moves the file at `originalPath` into quarantine and records it. Returns the
    /// recorded item so the caller can keep it for an immediate restore.
    @discardableResult
    public static func disable(originalPath: String, kind: String) throws -> Item {
        let kindDir = baseDir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)

        let src = URL(fileURLWithPath: originalPath)
        let dest = uniqueDestination(kindDir.appendingPathComponent(src.lastPathComponent))
        try FileManager.default.moveItem(at: src, to: dest)

        let item = Item(
            originalPath: originalPath,
            quarantinedPath: dest.path,
            kind: kind,
            disabledAt: Date()
        )
        var items = list()
        items.removeAll { $0.originalPath == originalPath }
        items.append(item)
        // If the manifest write fails, undo the move so the file isn't stranded in
        // quarantine with no record (un-restorable from the UI). Keep file and
        // manifest consistent: either both reflect the disable, or neither does.
        do {
            try save(items)
        } catch {
            try? FileManager.default.moveItem(at: dest, to: src)
            throw error
        }
        return item
    }

    /// Moves a quarantined file back to where it came from and forgets it.
    public static func restore(_ item: Item) throws {
        let src = URL(fileURLWithPath: item.quarantinedPath)
        let dest = URL(fileURLWithPath: item.originalPath)
        if FileManager.default.fileExists(atPath: src.path) {
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: src, to: dest)
        }
        var items = list()
        items.removeAll { $0.originalPath == item.originalPath }
        try save(items)
    }

    /// Every currently-disabled item. Empty (never throws) if nothing is stored.
    public static func list() -> [Item] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Item].self, from: data)) ?? []
    }

    // MARK: - Helpers

    private static func save(_ items: [Item]) throws {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(items).write(to: manifestURL, options: .atomic)
    }

    /// Avoids clobbering an existing quarantined file with the same name.
    private static func uniqueDestination(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 1
        while true {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
