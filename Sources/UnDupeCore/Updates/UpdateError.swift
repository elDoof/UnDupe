import Foundation

/// Everything that can go wrong between "check for updates" and "relaunch".
///
/// Each case carries a message the UI can show verbatim: an updater that fails
/// silently is worse than one that doesn't exist, because the user goes on
/// believing they're current.
public enum UpdateError: LocalizedError, Equatable {
    case notInstalledAsApp
    case unsignedBuild
    case networkFailure(String)
    case rateLimited
    case malformedFeed(String)
    case noDownloadableAsset(tag: String)
    case downloadFailed(String)
    case diskImageFailed(String)
    case appMissingFromDiskImage
    case signatureRejected(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalledAsApp:
            return "UnDupe can only update itself when it's running as an installed app."
        case .unsignedBuild:
            return "This build isn't code-signed, so UnDupe can't verify an update against it. Download the release manually."
        case .networkFailure(let detail):
            return "Couldn't reach GitHub: \(detail)"
        case .rateLimited:
            return "GitHub is rate-limiting update checks right now. Try again later."
        case .malformedFeed(let detail):
            return "GitHub returned something unexpected: \(detail)"
        case .noDownloadableAsset(let tag):
            return "Release \(tag) has no disk image attached to it."
        case .downloadFailed(let detail):
            return "The download didn't finish: \(detail)"
        case .diskImageFailed(let detail):
            return "Couldn't open the downloaded disk image: \(detail)"
        case .appMissingFromDiskImage:
            return "The downloaded disk image doesn't contain UnDupe."
        case .signatureRejected(let detail):
            return "The update was refused: \(detail)"
        case .installFailed(let detail):
            return "Couldn't replace the installed app: \(detail)"
        }
    }
}
