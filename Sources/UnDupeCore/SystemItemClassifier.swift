import Foundation

/// Who owns a system item (a launch agent, extension, plugin, app…). This single
/// classification drives a consistent safety posture across every cleanup module:
/// Apple-owned items are never actionable, third-party system items need admin
/// rights (reveal-only for now), and user items are freely actionable.
public enum ItemOwner: String, Sendable {
    /// Apple-owned or SIP-protected (under `/System`, or a `com.apple.*` bundle id).
    /// UnDupe will never disable or delete these — they are shown for transparency
    /// only.
    case apple

    /// Third-party, installed system-wide under `/Library`. Changing these needs
    /// administrator rights, so v1 surfaces them as reveal-in-Finder only.
    case system

    /// Lives in the user's home (`~/Library/...`). Safe for the user to act on
    /// directly, the same domain UnDupe already trashes from.
    case user

    /// A short, human-facing label for the owner badge.
    public var label: String {
        switch self {
        case .apple:  return "Apple"
        case .system: return "System"
        case .user:   return "User"
        }
    }
}

/// Classifies a discovered item by the path it lives at and, when available, its
/// bundle identifier. Path-based rules are exact for the launchd/plugin domains
/// macOS uses; the bundle id is a hint that catches Apple items installed under
/// `/Library` (e.g. `com.apple.*` daemons dropped by Apple packages).
public enum SystemItemClassifier {

    /// Returns the owner of an item at `path`. Pass `bundleIdentifier` (a launchd
    /// Label or a bundle's `CFBundleIdentifier`) when known for a sharper result.
    public static func owner(path: String, bundleIdentifier: String? = nil) -> ItemOwner {
        if let id = bundleIdentifier?.lowercased(),
           id.hasPrefix("com.apple.") || id == "com.apple" {
            return .apple
        }

        let normalized = (path as NSString).standardizingPath

        if normalized == "/System" || normalized.hasPrefix("/System/") {
            return .apple
        }

        let home = NSHomeDirectory()
        if normalized == home || normalized.hasPrefix(home + "/") {
            return .user
        }

        // Everything else installed under a system Library is third-party system.
        return .system
    }

    /// Whether UnDupe may disable/remove an item with this owner from inside the
    /// app. Only user-domain items qualify; Apple and system items are reveal-only.
    public static func isActionable(_ owner: ItemOwner) -> Bool {
        owner == .user
    }
}
