import Foundation

/// Decides whether a path is safe for the user to remove.
///
/// UnDupe never deletes anything vital. This guard is the last line of
/// defense before any file is sent to the Trash: even if the UI offered
/// a delete action, a protected path is refused here.
public enum ProtectedPaths {

    /// Absolute path prefixes that must never be deleted by UnDupe.
    /// Anything at or beneath these roots is considered system-critical.
    private static let protectedPrefixes: [String] = [
        "/System",
        "/private",
        "/usr",
        "/bin",
        "/sbin",
        "/Library",          // system-wide Library (not the user's ~/Library)
        "/Applications",     // installed apps — removing files inside breaks them
        "/cores",
        "/dev",
        "/Volumes/Recovery",
    ]

    /// Path suffixes that indicate a file lives *inside* a bundle (.app, .framework,
    /// etc.). Deleting individual files inside a bundle corrupts the bundle, so we
    /// refuse. The user can still remove the whole bundle in Finder.
    private static let bundleMarkers: [String] = [
        ".app/", ".framework/", ".bundle/", ".xpc/", ".kext/", ".appex/",
    ]

    /// Returns true when the path is safe to send to the Trash.
    public static func isDeletable(_ path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath

        for prefix in protectedPrefixes {
            if normalized == prefix || normalized.hasPrefix(prefix + "/") {
                return false
            }
        }

        for marker in bundleMarkers where normalized.contains(marker) {
            return false
        }

        // Refuse the user's home root itself.
        let home = NSHomeDirectory()
        if normalized == home { return false }

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
        let normalized = (path as NSString).standardizingPath
        guard normalized.hasSuffix(".app") else { return false }

        // Refuse a bundle nested inside another bundle (e.g. a helper app under
        // .../Contents/...). Only top-level application bundles qualify.
        let container = (normalized as NSString).deletingLastPathComponent
        for marker in bundleMarkers where container.contains(marker) {
            return false
        }

        // Never Apple's own apps.
        if normalized == "/System" || normalized.hasPrefix("/System/") { return false }
        if let id = bundleID?.lowercased(), id.hasPrefix("com.apple.") || id == "com.apple" {
            return false
        }

        // Never UnDupe itself.
        if normalized.hasSuffix("/UnDupe.app") { return false }

        return true
    }

    /// Whether a path lives in the user's home domain (`~/...`). This is the only
    /// domain the cleanup modules act on directly: system-wide (`/Library`) and
    /// Apple (`/System`) items are surfaced for transparency but reveal-only,
    /// since removing them needs administrator rights we don't take in-app.
    public static func isUserDomain(_ path: String) -> Bool {
        let normalized = (path as NSString).standardizingPath
        let home = NSHomeDirectory()
        return normalized == home || normalized.hasPrefix(home + "/")
    }
}
