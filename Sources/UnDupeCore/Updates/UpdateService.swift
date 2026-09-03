import Foundation

/// The update feature's front door: one object the app layer can drive without
/// knowing anything about GitHub, disk images or code signing.
public struct UpdateService: Sendable {

    public enum Outcome: Equatable, Sendable {
        case upToDate(current: AppVersion)
        case updateAvailable(Release)
    }

    private let feed: ReleaseFeed
    private let installer = UpdateInstaller()

    public init(owner: String, repo: String) {
        self.feed = ReleaseFeed(owner: owner, repo: repo)
    }

    /// Where to send a user who'd rather install the update by hand.
    public var releasesPageURL: URL { feed.releasesPageURL }

    /// Asks GitHub what the newest release is and compares it to this build.
    ///
    /// A release that is the same as, or older than, the running version counts
    /// as up to date — the updater never offers a downgrade.
    public func check(against current: AppVersion) async throws -> Outcome {
        let release = try await feed.latest()
        guard release.version > current else { return .upToDate(current: current) }
        return .updateAvailable(release)
    }

    /// Downloads `release` and replaces the running app with it.
    ///
    /// - Returns: the path of the installed app, ready to be relaunched.
    @discardableResult
    public func install(_ release: Release, bundle: Bundle = .main) async throws -> URL {
        let installed = try UpdateInstaller.installedBundleURL(bundle: bundle)

        // "Signed by whoever signed me" — read from the running app rather than
        // hard-coded, so the rule can't drift from reality and an unsigned local
        // build correctly refuses to update itself.
        guard let teamID = UpdateVerifier.teamIdentifier(ofBundleAt: installed), !teamID.isEmpty else {
            throw UpdateError.unsignedBuild
        }

        let diskImage = try await installer.download(release)
        defer { try? FileManager.default.removeItem(at: diskImage.deletingLastPathComponent()) }

        return try installer.install(
            diskImageAt: diskImage,
            replacing: installed,
            expectedTeamID: teamID
        )
    }

    /// Whether this build is even capable of updating itself. Used to hide the
    /// menu item in development builds instead of letting it fail on click.
    public static func isSelfUpdateSupported(bundle: Bundle = .main) -> Bool {
        guard let installed = try? UpdateInstaller.installedBundleURL(bundle: bundle) else {
            return false
        }
        guard let teamID = UpdateVerifier.teamIdentifier(ofBundleAt: installed) else { return false }
        return !teamID.isEmpty
    }
}
