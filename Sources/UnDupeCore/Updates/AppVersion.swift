import Foundation

/// A three-part version number, ordered the way humans expect.
///
/// Only used to answer one question — "is the release on GitHub newer than the
/// copy that's running?" — so it is deliberately small: no pre-release
/// identifiers, no build metadata. A tag that doesn't parse is treated as "not
/// an update" rather than being guessed at, which keeps a stray tag like
/// `nightly` from ever triggering an install.
public struct AppVersion: Comparable, CustomStringConvertible, Equatable, Sendable {

    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `1.2.3`, `v1.2.3`, `1.2` or `1`. Returns `nil` for anything else.
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        guard !text.isEmpty else { return nil }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 3 else { return nil }

        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }

        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// The version of the running app, read from its bundle. `nil` when there is
    /// no bundle to read — a `swift run` build, or a test host — which is what
    /// disables updating outside a real install.
    public static func current(bundle: Bundle = .main) -> AppVersion? {
        guard let raw = bundle.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return AppVersion(raw)
    }
}
