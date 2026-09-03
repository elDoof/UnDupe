import XCTest
@testable import UnDupeCore

/// The updater decides, on its own, whether to replace the app the user is
/// running. These tests pin down the two decisions that matter: which tags count
/// as "newer", and which release payloads are installable at all.
///
/// The security boundary itself (`UpdateVerifier`) is a code-signature check
/// against the running bundle, so it can only be exercised end-to-end from a
/// signed `.app`; what is covered here is that it refuses by default.
final class UpdateTests: XCTestCase {

    // MARK: - Version ordering

    func testParsesTagsWithAndWithoutALeadingV() {
        XCTAssertEqual(AppVersion("1.2.3"), AppVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(AppVersion("v1.2.3"), AppVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(AppVersion("v0.2"), AppVersion(major: 0, minor: 2, patch: 0),
                       "a two-part tag fills the patch with zero")
        XCTAssertEqual(AppVersion("3"), AppVersion(major: 3, minor: 0, patch: 0))
    }

    func testRejectsTagsThatArentVersionNumbers() {
        for tag in ["nightly", "", "v", "1.2.3.4", "1.x", "-1.0.0", "latest"] {
            XCTAssertNil(AppVersion(tag),
                         "“\(tag)” must not parse — a guess here could trigger a bad install")
        }
    }

    func testOrdersVersionsByComponentNotByString() {
        XCTAssertLessThan(AppVersion("0.2.0")!, AppVersion("0.10.0")!,
                          "0.10 is newer than 0.2 — string ordering would get this backwards")
        XCTAssertLessThan(AppVersion("0.9.9")!, AppVersion("1.0.0")!)
        XCTAssertLessThan(AppVersion("1.0.0")!, AppVersion("1.0.1")!)
        XCTAssertEqual(AppVersion("1.0.0")!, AppVersion("v1.0.0")!)
    }

    // MARK: - Release payloads

    /// A minimal payload shaped like GitHub's, with the fields under test made
    /// substitutable.
    private func payload(
        tag: String = "v0.3.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assets: String = #"[{"name":"UnDupe-0.3.0.dmg","size":2600000,"browser_download_url":"https://github.com/o/r/releases/download/v0.3.0/UnDupe-0.3.0.dmg"}]"#
    ) -> Data {
        Data("""
        {"tag_name":"\(tag)","body":"Notes.","draft":\(draft),"prerelease":\(prerelease),"assets":\(assets)}
        """.utf8)
    }

    func testReadsTheDiskImageOutOfAWellFormedRelease() throws {
        let release = try ReleaseFeed.parse(payload())

        XCTAssertEqual(release.version, AppVersion(major: 0, minor: 3, patch: 0))
        XCTAssertEqual(release.tag, "v0.3.0")
        XCTAssertEqual(release.assetName, "UnDupe-0.3.0.dmg")
        XCTAssertEqual(release.notes, "Notes.")
    }

    func testIgnoresNonDiskImageAssets() throws {
        let assets = #"""
        [{"name":"Source.zip","size":10,"browser_download_url":"https://x/Source.zip"},
         {"name":"UnDupe-0.3.0.dmg","size":20,"browser_download_url":"https://x/UnDupe-0.3.0.dmg"}]
        """#
        let release = try ReleaseFeed.parse(payload(assets: assets))

        XCTAssertEqual(release.assetName, "UnDupe-0.3.0.dmg",
                       "a source archive is not something the updater can install")
    }

    func testRefusesAReleaseWithNoDiskImage() {
        let assets = #"[{"name":"Source.zip","size":10,"browser_download_url":"https://x/Source.zip"}]"#

        XCTAssertThrowsError(try ReleaseFeed.parse(payload(assets: assets))) { error in
            XCTAssertEqual(error as? UpdateError, .noDownloadableAsset(tag: "v0.3.0"))
        }
    }

    func testRefusesDraftsAndPreReleases() {
        XCTAssertThrowsError(try ReleaseFeed.parse(payload(draft: true)),
                            "a draft is not published and must never be offered")
        XCTAssertThrowsError(try ReleaseFeed.parse(payload(prerelease: true)),
                            "a pre-release must be opted into, not pushed at everyone")
    }

    func testRefusesATagThatIsntAVersion() {
        XCTAssertThrowsError(try ReleaseFeed.parse(payload(tag: "nightly")))
    }

    func testRefusesADownloadLinkThatIsntHTTPS() {
        let assets = #"[{"name":"U.dmg","size":1,"browser_download_url":"http://x/U.dmg"}]"#

        XCTAssertThrowsError(try ReleaseFeed.parse(payload(assets: assets)),
                            "a plaintext download link must be rejected outright")
    }

    // MARK: - Refusing by default

    func testVerificationRefusesWhenThereIsNoTeamToPinAgainst() {
        XCTAssertThrowsError(
            try UpdateVerifier.verify(bundleAt: URL(fileURLWithPath: "/tmp/nope.app"),
                                      isSignedBy: "")
        ) { error in
            XCTAssertEqual(error as? UpdateError, .unsignedBuild,
                           "with no team identifier there is nothing to verify against")
        }
    }

    func testVerificationRefusesSomethingThatIsntSignedCode() {
        XCTAssertThrowsError(
            try UpdateVerifier.verify(bundleAt: URL(fileURLWithPath: "/etc/hosts"),
                                      isSignedBy: "DPLC4BD7ST")
        )
    }

    func testAnUnsignedPathHasNoTeamIdentifier() {
        XCTAssertNil(UpdateVerifier.teamIdentifier(ofBundleAt: URL(fileURLWithPath: "/etc/hosts")))
    }

    func testABuildThatIsNotAnAppCannotUpdateItself() {
        // The test bundle is an .xctest, not an .app.
        XCTAssertThrowsError(try UpdateInstaller.installedBundleURL(bundle: Bundle(for: Self.self))) {
            XCTAssertEqual($0 as? UpdateError, .notInstalledAsApp)
        }
        XCTAssertFalse(UpdateService.isSelfUpdateSupported(bundle: Bundle(for: Self.self)))
    }
}
