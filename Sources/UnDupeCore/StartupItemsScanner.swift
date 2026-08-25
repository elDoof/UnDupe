import Foundation

/// One launchd-managed startup/background item (a LaunchAgent or LaunchDaemon).
///
/// CleanMyMac's "background items" are, underneath, launchd jobs — not arbitrary
/// running PIDs. We surface whether each job is currently loaded rather than
/// offering a process killer, because killing a live PID isn't persistent: the
/// job just relaunches on next login. Disabling/removing the plist is the real fix.
public struct StartupItem: Identifiable, Hashable, Sendable {

    public enum Kind: String, Sendable {
        case userAgent      // ~/Library/LaunchAgents — runs at login, per-user
        case systemAgent    // /Library/LaunchAgents — runs at login, all users
        case daemon         // /Library/LaunchDaemons — runs at boot, as root

        public var label: String {
            switch self {
            case .userAgent:   return "Login Item (you)"
            case .systemAgent: return "Login Item (all users)"
            case .daemon:      return "Background Daemon"
            }
        }
    }

    public var id: String { plistPath }
    /// The launchd `Label` (usually a bundle-id-like string), or the filename.
    public let label: String
    public let plistPath: String
    /// The executable it launches (`Program` or first of `ProgramArguments`).
    public let program: String?
    public let kind: Kind
    public let owner: ItemOwner
    /// Currently loaded into launchd (appears in `launchctl list`).
    public let isLoaded: Bool
    /// Size of the plist on disk, for the trash-reclaim readout.
    public let sizeBytes: Int64

    /// Whether UnDupe will let the user disable/remove this in-app. Only
    /// user-domain agents qualify; Apple and system items are reveal-only.
    public var isActionable: Bool { SystemItemClassifier.isActionable(owner) }
}

/// Discovers launchd startup items and performs reversible disable / restore /
/// remove on the user-domain ones. All filesystem mutation goes through
/// `QuarantineStore` (disable) or `SafeDelete` (remove) — never a raw `unlink`.
public enum StartupItemsScanner {

    /// Directories scanned, paired with the kind they contain. `/System/Library`
    /// is intentionally omitted: it holds hundreds of Apple jobs the user can
    /// never act on, and listing them is pure noise.
    private static func sources() -> [(dir: String, kind: StartupItem.Kind)] {
        let home = NSHomeDirectory()
        return [
            ("\(home)/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .systemAgent),
            ("/Library/LaunchDaemons", .daemon),
        ]
    }

    // MARK: - Scan

    /// Returns every discoverable startup item, sorted user-domain first (the ones
    /// the user can act on), then by label.
    public static func scan() -> [StartupItem] {
        let loaded = loadedLabels()
        var items: [StartupItem] = []

        for source in sources() {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: source.dir)) ?? []
            for entry in contents where entry.hasSuffix(".plist") {
                let plistPath = "\(source.dir)/\(entry)"
                guard let item = makeItem(plistPath: plistPath, kind: source.kind, loaded: loaded) else { continue }
                items.append(item)
            }
        }

        return items.sorted { lhs, rhs in
            if lhs.isActionable != rhs.isActionable { return lhs.isActionable }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    private static func makeItem(plistPath: String, kind: StartupItem.Kind, loaded: Set<String>) -> StartupItem? {
        let url = URL(fileURLWithPath: plistPath)
        let data = (try? Data(contentsOf: url)) ?? Data()
        let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]

        let label = (plist?["Label"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let program = (plist?["Program"] as? String)
            ?? (plist?["ProgramArguments"] as? [String])?.first

        let size = (try? FileManager.default.attributesOfItem(atPath: plistPath)[.size] as? Int64) ?? 0
        let owner = SystemItemClassifier.owner(path: plistPath, bundleIdentifier: label)

        return StartupItem(
            label: label,
            plistPath: plistPath,
            program: program,
            kind: kind,
            owner: owner,
            isLoaded: loaded.contains(label),
            sizeBytes: size
        )
    }

    // MARK: - Actions (user-domain only)

    /// Reversibly disables a user agent: unloads it from launchd, then moves its
    /// plist into the quarantine store so it won't load next login.
    public static func disable(_ item: StartupItem) throws -> QuarantineStore.Item {
        guard item.isActionable else { throw CleanupError.notActionable(item.label) }
        _ = runLaunchctl(["unload", item.plistPath])
        return try QuarantineStore.disable(originalPath: item.plistPath, kind: item.kind.rawValue)
    }

    /// Restores a previously disabled item and reloads it into launchd.
    public static func enable(_ quarantined: QuarantineStore.Item) throws {
        try QuarantineStore.restore(quarantined)
        _ = runLaunchctl(["load", quarantined.originalPath])
    }

    /// Permanently removes a user agent's plist (to the Trash, recoverable).
    public static func remove(_ item: StartupItem) -> TrashResult {
        guard item.isActionable else {
            return TrashResult(
                path: item.plistPath,
                success: false,
                reclaimedBytes: 0,
                error: "Only your own login items can be removed here."
            )
        }
        _ = runLaunchctl(["unload", item.plistPath])
        return SafeDelete.moveToTrash([.init(path: item.plistPath, size: item.sizeBytes)]).first
            ?? TrashResult(path: item.plistPath, success: false, reclaimedBytes: 0, error: "Unknown error")
    }

    // MARK: - launchctl

    /// Labels currently loaded into launchd, parsed from `launchctl list`
    /// (columns: PID, Status, Label). Read-only.
    private static func loadedLabels() -> Set<String> {
        guard let output = runLaunchctl(["list"]) else { return [] }
        var labels: Set<String> = []
        for line in output.split(separator: "\n").dropFirst() {   // drop header row
            let columns = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if let last = columns.last { labels.insert(String(last)) }
        }
        return labels
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

/// Errors surfaced by the cleanup engine.
public enum CleanupError: LocalizedError {
    case notActionable(String)

    public var errorDescription: String? {
        switch self {
        case .notActionable(let label):
            return "\(label) is a system item and can't be changed from inside UnDupe."
        }
    }
}
