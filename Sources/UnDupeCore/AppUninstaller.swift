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

    /// A candidate leftover before it's been confirmed to exist and sized: one
    /// entry named `name` directly inside the `~/Library` subfolder `folder`.
    private struct LeftoverCandidate {
        let category: String
        let folder: String
        let name: String

        func path(home: String) -> String { "\(home)/Library/\(folder)/\(name)" }
    }

    /// Whether `token` is safe to use as a single path component.
    ///
    /// The bundle identifier and display name come out of the app's own
    /// `Info.plist`, which makes them untrusted input: an identifier of
    /// `../../Documents` would otherwise turn `~/Library/Caches/<id>` into the
    /// user's Documents folder, and an empty display name would turn
    /// `~/Library/Application Support/<name>` into the whole folder. Anything
    /// that isn't a plain name is refused outright rather than cleaned up.
    static func isSafePathToken(_ token: String) -> Bool {
        guard !token.isEmpty, token != ".", token != ".." else { return false }
        guard !token.contains("/") else { return false }
        return token.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    /// Support files under `home`'s Library that belong to the app with this
    /// bundle identifier and display name. `home` is a parameter so the matching
    /// rules can be tested against a scratch directory.
    static func findLeftovers(
        bundleID: String?,
        appName: String,
        home: String = NSHomeDirectory()
    ) -> [AppLeftover] {
        var candidates: [LeftoverCandidate] = []

        // Bundle-identifier-keyed locations (exact, collision-free).
        if let id = bundleID, isSafePathToken(id) {
            candidates += [
                LeftoverCandidate(category: "Preferences", folder: "Preferences", name: "\(id).plist"),
                LeftoverCandidate(category: "Caches", folder: "Caches", name: id),
                LeftoverCandidate(category: "Application Support", folder: "Application Support", name: id),
                LeftoverCandidate(category: "Containers", folder: "Containers", name: id),
                LeftoverCandidate(category: "Logs", folder: "Logs", name: id),
                LeftoverCandidate(category: "Saved State", folder: "Saved Application State", name: "\(id).savedState"),
                LeftoverCandidate(category: "HTTP Storage", folder: "HTTPStorages", name: id),
                LeftoverCandidate(category: "WebKit Data", folder: "WebKit", name: id),
                LeftoverCandidate(category: "Cookies", folder: "Cookies", name: "\(id).binarycookies"),
            ]

            // Group Containers embed the bundle/team id in the folder name.
            candidates += groupContainers(matching: id, home: home)
        }

        // Display-name-keyed locations (apps commonly use the title here). Exact
        // folder match only — no substring matching, to avoid collisions.
        if isSafePathToken(appName) {
            candidates += [
                LeftoverCandidate(category: "Application Support", folder: "Application Support", name: appName),
                LeftoverCandidate(category: "Logs", folder: "Logs", name: appName),
            ]
        }

        // Keep only the ones that exist, are deletable, and aren't duplicates.
        // The direct-child check is a second line of defence behind
        // `isSafePathToken`: whatever the name was, the resolved path must still
        // sit immediately inside the folder it was built for.
        let fm = FileManager.default
        var seen = Set<String>()
        let existing: [(category: String, path: String)] = candidates.compactMap { candidate in
            let path = candidate.path(home: home)
            guard seen.insert(path).inserted else { return nil }
            guard isDirectChild(path, of: "\(home)/Library/\(candidate.folder)") else { return nil }
            guard fm.fileExists(atPath: path), ProtectedPaths.isDeletable(path) else { return nil }
            return (candidate.category, path)
        }

        let sizes = FileSizing.parallelSizes(existing.map(\.path))
        return existing
            .map { AppLeftover(category: $0.category, path: $0.path, sizeBytes: sizes[$0.path] ?? 0) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Whether `path` resolves to an entry immediately inside `parent`.
    private static func isDirectChild(_ path: String, of parent: String) -> Bool {
        let resolved = (path as NSString).standardizingPath
        let resolvedParent = (parent as NSString).standardizingPath
        return (resolved as NSString).deletingLastPathComponent == resolvedParent
            && resolved != resolvedParent
    }

    /// Whether a Group Containers folder name belongs to `bundleID`: the id
    /// itself, or the id behind a dotted prefix (`group.com.foo.bar`,
    /// `<TEAMID>.com.foo.bar`). A plain substring test is not enough —
    /// `com.foo.bar` is a substring of `group.com.foo.barista`, which is a
    /// different app's data.
    static func isGroupContainer(_ name: String, for bundleID: String) -> Bool {
        if name == bundleID { return true }
        // A one-word identifier isn't a real reverse-DNS id, and as a suffix it
        // would match unrelated containers: `bar` ends `group.com.other.bar`.
        guard bundleID.contains(".") else { return false }
        return name.hasSuffix("." + bundleID)
    }

    private static func groupContainers(matching bundleID: String, home: String) -> [LeftoverCandidate] {
        let folder = "Group Containers"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "\(home)/Library/\(folder)")) ?? []
        return entries
            .filter { isGroupContainer($0, for: bundleID) }
            .map { LeftoverCandidate(category: "Group Containers", folder: folder, name: $0) }
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
