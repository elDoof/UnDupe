import Foundation

/// One support file an app left behind in the user's `~/Library`, grouped by the
/// kind of data it holds so the user can see exactly what an uninstall removes.
public struct AppLeftover: Identifiable, Hashable, Sendable {
    public var id: String { path }
    /// Human-facing group, e.g. "Preferences", "Caches", "Containers".
    public let category: String
    public let path: String
    public let sizeBytes: Int64
}

/// An application discovered in a user-facing Applications folder, with the
/// leftover files it would take down with it. Mirrors the cleanup modules' safety
/// posture: Apple apps are surfaced for transparency but never uninstalled
/// (`owner == .apple`); everything else is a user-installed app the carve-out in
/// `ProtectedPaths.isUninstallableApp` allows trashing.
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: String { bundlePath }
    public let name: String
    public let bundlePath: String
    public let bundleID: String?
    public let version: String?
    public let owner: ItemOwner
    public let bundleSizeBytes: Int64
    public let leftovers: [AppLeftover]

    public var leftoverBytes: Int64 { leftovers.reduce(0) { $0 + $1.sizeBytes } }
    public var totalBytes: Int64 { bundleSizeBytes + leftoverBytes }

    /// Whether UnDupe may uninstall this app in-app. Apple apps are reveal-only;
    /// everything else is gated by the `.app` carve-out (which also refuses
    /// `com.apple.*` ids and UnDupe itself as a backstop).
    public var canUninstall: Bool {
        owner != .apple && ProtectedPaths.isUninstallableApp(bundlePath, bundleID: bundleID)
    }
}

/// Finds installed apps and the support files they scatter under `~/Library`, then
/// uninstalls the user-installed ones (bundle + leftovers) to the Trash.
///
/// Discovery is intentionally narrow on two axes:
/// - **Where apps are found:** only the user-facing Applications folders, never
///   `/System/Applications`. Stray Apple apps that turn up are marked reveal-only.
/// - **Which leftovers are matched:** keyed on the app's *bundle identifier* (an
///   exact, collision-free token) in the standard `~/Library` support locations,
///   plus an exact display-name match for the two folders apps name by title
///   (Application Support, Logs). No fuzzy matching — a false positive here would
///   trash an unrelated app's data.
public enum AppUninstaller {

    /// User-facing Applications folders. `/System/Applications` is excluded on
    /// purpose so Apple's own apps never clutter (or risk) the uninstaller.
    private static func appDirectories() -> [String] {
        [
            "/Applications",
            "/Applications/Utilities",
            "\(NSHomeDirectory())/Applications",
        ]
    }

    // MARK: - Scan

    public static func scan() -> [InstalledApp] {
        let bundlePaths = discoverBundlePaths()

        // Size every bundle in parallel — app bundles can be large.
        let bundleSizes = FileSizing.parallelSizes(bundlePaths)

        let apps = bundlePaths.map { path -> InstalledApp in
            buildApp(bundlePath: path, bundleSize: bundleSizes[path] ?? 0)
        }

        return apps.sorted { lhs, rhs in
            // Uninstallable apps first, then by size, then by name.
            if lhs.canUninstall != rhs.canUninstall { return lhs.canUninstall }
            if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func discoverBundlePaths() -> [String] {
        let fm = FileManager.default
        var seen = Set<String>()
        var paths: [String] = []
        for dir in appDirectories() {
            let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for entry in entries where entry.hasSuffix(".app") {
                let full = "\(dir)/\(entry)"
                if seen.insert(full).inserted { paths.append(full) }
            }
        }
        return paths
    }

    // MARK: - One app

    private static func buildApp(bundlePath: String, bundleSize: Int64) -> InstalledApp {
        let bundle = Bundle(path: bundlePath)
        let info = bundle?.infoDictionary
        let bundleID = bundle?.bundleIdentifier

        let fallbackName = ((bundlePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? fallbackName
        let version = info?["CFBundleShortVersionString"] as? String

        let isApple = bundlePath.hasPrefix("/System/")
            || (bundleID?.lowercased().hasPrefix("com.apple.") ?? false)
        let owner: ItemOwner = isApple ? .apple : .user

        // Apple apps are reveal-only; don't bother hunting their leftovers.
        let leftovers = isApple
            ? []
            : findLeftovers(bundleID: bundleID, appName: name)

        return InstalledApp(
            name: name,
            bundlePath: bundlePath,
            bundleID: bundleID,
            version: version,
            owner: owner,
            bundleSizeBytes: bundleSize,
            leftovers: leftovers
        )
    }

    // MARK: - Leftovers

    /// A candidate leftover before it's been confirmed to exist and sized.
    private struct LeftoverCandidate { let category: String; let path: String }

    private static func findLeftovers(bundleID: String?, appName: String) -> [AppLeftover] {
        let home = NSHomeDirectory()
        var candidates: [LeftoverCandidate] = []

        // Bundle-identifier-keyed locations (exact, collision-free).
        if let id = bundleID, !id.isEmpty {
            candidates += [
                LeftoverCandidate(category: "Preferences", path: "\(home)/Library/Preferences/\(id).plist"),
                LeftoverCandidate(category: "Caches", path: "\(home)/Library/Caches/\(id)"),
                LeftoverCandidate(category: "Application Support", path: "\(home)/Library/Application Support/\(id)"),
                LeftoverCandidate(category: "Containers", path: "\(home)/Library/Containers/\(id)"),
                LeftoverCandidate(category: "Logs", path: "\(home)/Library/Logs/\(id)"),
                LeftoverCandidate(category: "Saved State", path: "\(home)/Library/Saved Application State/\(id).savedState"),
                LeftoverCandidate(category: "HTTP Storage", path: "\(home)/Library/HTTPStorages/\(id)"),
                LeftoverCandidate(category: "WebKit Data", path: "\(home)/Library/WebKit/\(id)"),
                LeftoverCandidate(category: "Cookies", path: "\(home)/Library/Cookies/\(id).binarycookies"),
            ]

            // Group Containers embed the bundle/team id in the folder name.
            candidates += groupContainers(matching: id, home: home)
        }

        // Display-name-keyed locations (apps commonly use the title here). Exact
        // folder match only — no substring matching, to avoid collisions.
        candidates += [
            LeftoverCandidate(category: "Application Support", path: "\(home)/Library/Application Support/\(appName)"),
            LeftoverCandidate(category: "Logs", path: "\(home)/Library/Logs/\(appName)"),
        ]

        // Keep only the ones that exist, are deletable, and aren't duplicates.
        let fm = FileManager.default
        var seen = Set<String>()
        let existing = candidates.filter { candidate in
            guard seen.insert(candidate.path).inserted else { return false }
            return fm.fileExists(atPath: candidate.path)
                && ProtectedPaths.isDeletable(candidate.path)
        }

        let sizes = FileSizing.parallelSizes(existing.map(\.path))
        return existing
            .map { AppLeftover(category: $0.category, path: $0.path, sizeBytes: sizes[$0.path] ?? 0) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Group-container folders whose name contains the bundle id (e.g.
    /// `group.com.foo.bar` or `<TEAMID>.com.foo.bar`).
    private static func groupContainers(matching bundleID: String, home: String) -> [LeftoverCandidate] {
        let dir = "\(home)/Library/Group Containers"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return entries
            .filter { $0.contains(bundleID) }
            .map { LeftoverCandidate(category: "Group Containers", path: "\(dir)/\($0)") }
    }

    // MARK: - Uninstall

    /// Uninstalls an app: trashes its bundle and the chosen subset of leftovers.
    /// Routes through `SafeDelete.uninstallApp`, so the bundle uses the `.app`
    /// carve-out and the leftovers use the normal guard. The user may keep some
    /// leftovers (e.g. preferences) by omitting their paths from `leftoverPaths`.
    /// Recoverable until the Trash is emptied.
    public static func uninstall(_ app: InstalledApp, includingLeftovers leftoverPaths: Set<String>) -> [TrashResult] {
        let chosen = app.leftovers.filter { leftoverPaths.contains($0.path) }
        return SafeDelete.uninstallApp(
            bundlePath: app.bundlePath,
            bundleID: app.bundleID,
            bundleSize: app.bundleSizeBytes,
            leftovers: chosen.map { .init(path: $0.path, size: $0.sizeBytes) }
        )
    }

    /// Convenience: uninstalls an app with *all* of its detected leftovers.
    public static func uninstall(_ app: InstalledApp) -> [TrashResult] {
        uninstall(app, includingLeftovers: Set(app.leftovers.map(\.path)))
    }
}
