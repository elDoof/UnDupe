import Foundation

/// A published release that UnDupe could update to.
public struct Release: Equatable, Sendable {
    public let version: AppVersion
    public let tag: String
    /// The release body, shown as "what's new". May be empty.
    public let notes: String
    public let assetName: String
    public let downloadURL: URL
    public let assetSize: Int64
}

/// Reads the latest release from a GitHub repository's public API.
///
/// Only the *metadata* is trusted from here. The download URL this returns is
/// treated as untrusted input: what makes an update safe is the code-signature
/// check in `UpdateVerifier`, not the fact that GitHub served the bytes.
public struct ReleaseFeed: Sendable {

    private let owner: String
    private let repo: String
    private let session: URLSession

    public init(owner: String, repo: String, session: URLSession = .shared) {
        self.owner = owner
        self.repo = repo
        self.session = session
    }

    public var releasesPageURL: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
    }

    /// Fetches the newest non-draft, non-prerelease release.
    public func latest() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        // GitHub rejects API requests without a User-Agent.
        request.setValue("UnDupe", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 20
        // An update check must never serve a cached "you're current".
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.networkFailure(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200: break
            case 403, 429: throw UpdateError.rateLimited
            case 404: throw UpdateError.malformedFeed("no published release found")
            default: throw UpdateError.networkFailure("HTTP \(http.statusCode)")
            }
        }

        return try Self.parse(data)
    }

    /// Split out from the network call so the parsing rules can be tested
    /// against fixture payloads without touching the network.
    static func parse(_ data: Data) throws -> Release {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw UpdateError.malformedFeed(error.localizedDescription)
        }

        guard let version = AppVersion(payload.tagName) else {
            throw UpdateError.malformedFeed("tag “\(payload.tagName)” isn't a version number")
        }
        guard !payload.draft, !payload.prerelease else {
            throw UpdateError.malformedFeed("the latest release is a draft or pre-release")
        }

        // Only a disk image is installable; ignore source tarballs and anything
        // else someone may have attached to the release.
        guard let asset = payload.assets.first(where: {
            $0.name.lowercased().hasSuffix(".dmg")
        }) else {
            throw UpdateError.noDownloadableAsset(tag: payload.tagName)
        }
        guard let url = URL(string: asset.browserDownloadURL), url.scheme == "https" else {
            throw UpdateError.malformedFeed("the download link isn't a valid HTTPS URL")
        }

        return Release(
            version: version,
            tag: payload.tagName,
            notes: (payload.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            assetName: asset.name,
            downloadURL: url,
            assetSize: asset.size
        )
    }

    // MARK: - Wire format

    private struct Payload: Decodable {
        let tagName: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body, draft, prerelease, assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let size: Int64
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }
}
