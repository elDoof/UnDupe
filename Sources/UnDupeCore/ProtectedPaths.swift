import Foundation

/// Decides whether a path is safe for the user to remove.
///
/// UnDupe never deletes anything vital. This guard is the last line of
/// defense before any file is sent to the Trash: even if the UI offered
/// a delete action, a protected path is refused here.
public enum ProtectedPaths {

    /// Absolute path prefixes that must never be deleted by UnDupe.
    /// Anything at or beneath these roots is considered system-critical.
    ///
    /// Written in lower case, like every other rule here: paths are compared
    /// case-folded (see `canonical`), because the default macOS filesystem
    /// treats `/library` and `/Library` as the same place.
    private static let protectedPrefixes: [String] = [
        "/system",
        "/private",
        "/usr",
        "/bin",
        "/sbin",
        "/library",          // system-wide Library (not the user's ~/Library)
        "/applications",     // installed apps — removing files inside breaks them
        "/cores",
        "/dev",
        "/etc",              // reached as /private/etc; see `canonical`
        "/var",
        "/volumes/recovery",
    ]

    /// Roots that are refused themselves but whose *contents* are the user's to
    /// clear, even though they sit under an otherwise protected prefix:
    /// `/tmp` is scratch by definition, and `/var/folders` holds each user's
    /// temporary and cache directories.
    private static let scratchRoots: [String] = ["/tmp", "/var/folders"]

    /// Exact paths that are never removable: the roots everything else hangs
    /// from. The OS refuses most of these anyway, but refusing here means the UI
    /// never offers an action that can only fail.
    private static let protectedExactPaths: Set<String> = ["/", "/users", "/volumes"]

    /// Folders whose direct children are refused while anything deeper is
    /// ordinary content: a child of `/Volumes` is a whole mounted volume, and a
    /// child of `/Users` is somebody's entire home folder (or `Shared`).
    private static let containerRoots: [String] = ["/volumes/", "/users/"]

    /// Top-level directories that macOS keeps under `/private` and exposes
    /// through a symlink at the root.
    private static let privateAliases: [String] = ["etc", "var", "tmp"]

    /// The path in the one spelling every rule below is written against.
    ///
    /// Three things are normalised away, each of which once let a protected
    /// location through under a different name:
    ///
    /// - **Symlinked folders.** `/Volumes/Macintosh HD` is a symlink to `/`, so
    ///   a scan started there reports `/Volumes/Macintosh HD/Library/…` — the
    ///   system Library, under a path no prefix rule matches. The *containing
    ///   folder* is resolved; the last component is left alone, because
    ///   trashing a symlink removes the link, not what it points at.
    /// - **The `/private` aliases.** `standardizingPath` drops a leading
    ///   `/private` only when the shortened path exists, so `/private/etc/hosts`
    ///   and `/private/etc/nope` come back spelled differently. The three
    ///   aliased directories are folded to their short form unconditionally.
    /// - **Letter case.** The default macOS filesystem is case-insensitive, so
    ///   the result is lower-cased and every rule is written in lower case.
    private static func canonical(_ path: String) -> String {
        let resolved = resolvingContainingFolder((path as NSString).standardizingPath)
        return foldingPrivateAliases(resolved).lowercased()
    }

    private static func resolvingContainingFolder(_ path: String) -> String {
        let components = path as NSString
        let parent = components.deletingLastPathComponent
        guard path != "/", !parent.isEmpty else { return path }
        let resolvedParent = (parent as NSString).resolvingSymlinksInPath
        return (resolvedParent as NSString).appendingPathComponent(components.lastPathComponent)
    }

    private static func foldingPrivateAliases(_ path: String) -> String {
        for alias in privateAliases {
            let long = "/private/" + alias
            if path == long { return "/" + alias }
            if path.hasPrefix(long + "/") {
                return String(path.dropFirst("/private".count))
            }
        }
        return path
    }

    private static func isAtOrBeneath(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    /// True for a direct child of one of `containerRoots` — `/Volumes/<name>`
    /// or `/Users/<name>` exactly.
    private static func isContainerRootChild(_ path: String) -> Bool {
        containerRoots.contains { root in
            guard path.hasPrefix(root) else { return false }
            let name = path.dropFirst(root.count)
            return !name.isEmpty && !name.contains("/")
        }
    }

    /// True for `~/Library` and the folders directly inside it. Those are the
    /// containers every app's data lives in (Application Support, Preferences,
    /// Containers…); the cleanup modules only ever remove items *within* them.
    private static func isUserLibraryContainer(_ path: String, home: String) -> Bool {
        let library = home + "/library"
        if path == library { return true }
        guard path.hasPrefix(library + "/") else { return false }
        return !path.dropFirst(library.count + 1).contains("/")
    }

    /// Path suffixes that indicate a file lives *inside* a bundle (.app, .framework,
    /// etc.). Deleting individual files inside a bundle corrupts the bundle, so we
    /// refuse. The user can still remove the whole bundle in Finder.
    private static let bundleMarkers: [String] = [
        ".app/", ".framework/", ".bundle/", ".xpc/", ".kext/", ".appex/",
    ]

    /// Returns true when the path is safe to send to the Trash.
    public static func isDeletable(_ path: String) -> Bool {
        let normalized = canonical(path)

        if protectedExactPaths.contains(normalized) { return false }
        if scratchRoots.contains(normalized) { return false }
        if isContainerRootChild(normalized) { return false }

        let isScratchContent = scratchRoots.contains { normalized.hasPrefix($0 + "/") }
        if !isScratchContent {
            for prefix in protectedPrefixes where isAtOrBeneath(normalized, prefix) {
                return false
            }
        }

        for marker in bundleMarkers where normalized.contains(marker) {
            return false
        }

        // Refuse the user's home root itself, and the Library containers in it.
        let home = canonical(NSHomeDirectory())
        if normalized == home { return false }
        if isUserLibraryContainer(normalized, home: home) { return false }

        return true
    }

    /// Human-readable reason a path was refused, for surfacing in the UI.
    public static func refusalReason(_ path: String) -> String? {
        isDeletable(path) ? nil : "This item is protected by UnDupe and can't be removed here."
    }

    /// The App Uninstaller's single, narrow carve-out: a whole third-party `.app`
    /// bundle may be sent to the Trash even though `/Applications` and `.app`
    /// bundles are otherwise refused by `isDeletable`. This is deliberately strict:
    ///
    /// - the path must *be* an `.app` bundle (end in `.app`), never a file nested
    ///   inside one (which `isDeletable` still guards);
    /// - the bundle must not itself live inside another bundle;
    /// - it is never an Apple-shipped app (`/System/...` or a `com.apple.*` id);
    /// - UnDupe never uninstalls itself.
    ///
    /// Leftover files (caches, preferences, containers) are *not* covered here —
    /// they live under `~/Library` and pass the normal `isDeletable` guard.
    public static func isUninstallableApp(_ path: String, bundleID: String? = nil) -> Bool {
        let normalized = canonical(path)
        guard normalized.hasSuffix(".app") else { return false }

        // Refuse a bundle nested inside another bundle (e.g. a helper app under
        // .../Contents/...). Only top-level application bundles qualify.
        let container = (normalized as NSString).deletingLastPathComponent
        for marker in bundleMarkers where container.contains(marker) {
            return false
        }

        // Never Apple's own apps.
        if isAtOrBeneath(normalized, "/system") { return false }
        if let id = bundleID?.lowercased(), id.hasPrefix("com.apple.") || id == "com.apple" {
            return false
        }

        // Never UnDupe itself.
        if normalized.hasSuffix("/undupe.app") { return false }

        return true
    }

    /// Whether a path lives in the user's home domain (`~/...`). This is the only
    /// domain the cleanup modules act on directly: system-wide (`/Library`) and
    /// Apple (`/System`) items are surfaced for transparency but reveal-only,
    /// since removing them needs administrator rights we don't take in-app.
    public static func isUserDomain(_ path: String) -> Bool {
        isAtOrBeneath(canonical(path), canonical(NSHomeDirectory()))
    }
}
