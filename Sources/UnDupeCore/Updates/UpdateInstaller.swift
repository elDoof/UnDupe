import Foundation

/// Downloads a release and swaps it in for the running app.
///
/// The order of operations matters and is deliberate:
/// download → mount → copy out → **verify the copy** → atomic replace.
/// Verifying the copy rather than the image means the bytes that get checked are
/// exactly the bytes that end up running.
public struct UpdateInstaller: Sendable {

    private var fileManager: FileManager { .default }

    public init() {}

    // MARK: - Preflight

    /// The installed app that would be replaced.
    ///
    /// Throws when UnDupe isn't running from a writable `.app` — a `swift run`
    /// build, or a copy still running from inside a mounted disk image, neither
    /// of which can meaningfully replace itself.
    public static func installedBundleURL(bundle: Bundle = .main) throws -> URL {
        let url = bundle.bundleURL
        guard url.pathExtension == "app" else { throw UpdateError.notInstalledAsApp }

        // A read-only volume is the giveaway for "launched straight from the DMG".
        let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        if values?.volumeIsReadOnly == true { throw UpdateError.notInstalledAsApp }

        return url
    }

    // MARK: - Download

    /// Fetches the release's disk image into a fresh temporary directory.
    public func download(_ release: Release, session: URLSession = .shared) async throws -> URL {
        var request = URLRequest(url: release.downloadURL)
        request.setValue("UnDupe", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.downloadFailed("HTTP \(http.statusCode)")
        }

        // URLSession deletes its temp file as soon as this call returns, so the
        // download has to be moved somewhere we control first.
        let directory = try makeScratchDirectory(named: "download")
        let destination = directory.appendingPathComponent(release.assetName)
        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }
        return destination
    }

    // MARK: - Install

    /// Mounts `dmgURL`, verifies the app inside it against `expectedTeamID`, and
    /// replaces `installedURL` with it.
    ///
    /// - Returns: the path of the freshly installed app.
    @discardableResult
    public func install(
        diskImageAt dmgURL: URL,
        replacing installedURL: URL,
        expectedTeamID: String
    ) throws -> URL {
        let mountPoint = try mount(dmgURL)
        defer { detach(mountPoint) }

        guard let source = try? fileManager.contentsOfDirectory(
            at: mountPoint, includingPropertiesForKeys: nil
        ).first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appMissingFromDiskImage
        }

        // Stage on the same volume as the installed app: `replaceItem` is only
        // atomic within a volume, and copying first means a failed verification
        // never touches the installed copy.
        let staging = try makeScratchDirectory(named: "staged", nextTo: installedURL)
        let staged = staging.appendingPathComponent(source.lastPathComponent)
        do {
            try fileManager.copyItem(at: source, to: staged)
        } catch {
            throw UpdateError.installFailed(error.localizedDescription)
        }
        defer { try? fileManager.removeItem(at: staging) }

        // The trust boundary. Everything before this point is untrusted input.
        try UpdateVerifier.verify(bundleAt: staged, isSignedBy: expectedTeamID)

        do {
            _ = try fileManager.replaceItemAt(installedURL, withItemAt: staged)
        } catch {
            throw UpdateError.installFailed(error.localizedDescription)
        }
        return installedURL
    }

    // MARK: - Disk image handling

    private func mount(_ dmgURL: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "attach", dmgURL.path,
            "-nobrowse",            // don't clutter the user's Finder sidebar
            "-readonly",
            "-plist",
            // A downloaded image must never be allowed to open anything on mount.
            "-noautoopen",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw UpdateError.diskImageFailed(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError.diskImageFailed("hdiutil exited with \(process.terminationStatus)")
        }

        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw UpdateError.diskImageFailed("couldn't read hdiutil's reply")
        }
        guard let path = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.diskImageFailed("the image mounted with no mount point")
        }
        return URL(fileURLWithPath: path)
    }

    private func detach(_ mountPoint: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path, "-quiet"]
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Scratch space

    /// A private directory, beside `neighbour`'s volume when one is given so the
    /// final replace stays on a single volume.
    private func makeScratchDirectory(named name: String, nextTo neighbour: URL? = nil) throws -> URL {
        let parent: URL
        if let neighbour {
            parent = neighbour.deletingLastPathComponent()
        } else {
            parent = fileManager.temporaryDirectory
        }
        let directory = parent.appendingPathComponent(".UnDupeUpdate-\(name)-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw UpdateError.installFailed("couldn't create a staging folder: \(error.localizedDescription)")
        }
        return directory
    }
}
