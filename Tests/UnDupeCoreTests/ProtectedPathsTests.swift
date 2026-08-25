import XCTest
@testable import UnDupeCore

/// `ProtectedPaths` is the last line of defence before anything is removed —
/// every deletion in the app routes through it.
/// These tests pin that contract down in both directions: what it must refuse,
/// and what it must still allow so the app stays useful.
final class ProtectedPathsTests: XCTestCase {

    private let home = NSHomeDirectory()

    // MARK: - Refusals

    func testRefusesSystemCriticalRoots() {
        for path in ["/System", "/private", "/usr", "/bin", "/sbin",
                     "/Library", "/Applications", "/cores", "/dev", "/Volumes/Recovery"] {
            XCTAssertFalse(ProtectedPaths.isDeletable(path), "\(path) must be protected")
        }
    }

    func testRefusesAnythingBeneathASystemCriticalRoot() {
        for path in ["/System/Library/CoreServices/Finder.app",
                     "/usr/lib/libSystem.dylib",
                     "/Library/Preferences/com.apple.loginwindow.plist",
                     "/private/var/db/something"] {
            XCTAssertFalse(ProtectedPaths.isDeletable(path), "\(path) must be protected")
        }
    }

    func testRefusesFilesInsideBundles() {
        // Removing one file inside a bundle corrupts the whole bundle.
        for path in ["\(home)/Downloads/Thing.app/Contents/Info.plist",
                     "\(home)/Dev/My.framework/Versions/A/My",
                     "\(home)/Stuff/Some.bundle/Contents/Resources/x.png",
                     "\(home)/Stuff/Helper.xpc/Contents/MacOS/Helper",
                     "\(home)/Stuff/Ext.appex/Contents/MacOS/Ext"] {
            XCTAssertFalse(ProtectedPaths.isDeletable(path), "\(path) must be protected")
        }
    }

    func testRefusesTheHomeDirectoryItself() {
        XCTAssertFalse(ProtectedPaths.isDeletable(home))
    }

    func testRefusesPathsThatTraverseIntoAProtectedRoot() {
        // A guard that only string-matches the prefix would wave this through.
        XCTAssertFalse(ProtectedPaths.isDeletable("\(home)/../../System/Library"))
        XCTAssertFalse(ProtectedPaths.isDeletable("\(home)/Downloads/../../../usr/bin"))
    }

    func testGivesAReasonExactlyWhenItRefuses() {
        XCTAssertNotNil(ProtectedPaths.refusalReason("/System"))
        XCTAssertNil(ProtectedPaths.refusalReason("\(home)/Downloads/big.zip"))
    }

    // MARK: - Allowances

    func testAllowsOrdinaryUserFiles() {
        for path in ["\(home)/Downloads/big.zip",
                     "\(home)/Library/Caches/com.example.app",
                     "\(home)/Documents/notes.txt",
                     "/Volumes/Backup/old-video.mov"] {
            XCTAssertTrue(ProtectedPaths.isDeletable(path), "\(path) should be deletable")
        }
    }

    func testDoesNotConfuseTheUserLibraryWithTheSystemLibrary() {
        // "/Library" is protected; "~/Library" must stay cleanable or the whole
        // System Junk module has nothing to do.
        XCTAssertTrue(ProtectedPaths.isDeletable("\(home)/Library/Logs/old.log"))
        XCTAssertFalse(ProtectedPaths.isDeletable("/Library/Logs/old.log"))
    }

    func testDoesNotTreatAPrefixMatchAsAPathMatch() {
        // "/Librarian" merely starts with "/Library"'s letters.
        XCTAssertTrue(ProtectedPaths.isDeletable("/Volumes/Data/Librarian/notes"))
        XCTAssertTrue(ProtectedPaths.isDeletable("/Volumes/Data/usrdata/file"))
    }

    // MARK: - The App Uninstaller carve-out

    func testUninstallAllowsAThirdPartyApplication() {
        XCTAssertTrue(ProtectedPaths.isUninstallableApp("/Applications/Some Vendor.app",
                                                        bundleID: "com.vendor.app"))
    }

    func testUninstallRefusesAppleApplications() {
        XCTAssertFalse(ProtectedPaths.isUninstallableApp("/System/Applications/Mail.app",
                                                         bundleID: "com.apple.mail"))
        // Bundle id alone is enough, wherever it sits.
        XCTAssertFalse(ProtectedPaths.isUninstallableApp("/Applications/Xcode.app",
                                                         bundleID: "com.apple.dt.Xcode"))
    }

    func testUninstallRefusesUnDupeItself() {
        XCTAssertFalse(ProtectedPaths.isUninstallableApp("/Applications/UnDupe.app",
                                                         bundleID: "com.saschanowlin.UnDupe"))
    }

    func testUninstallRefusesNestedHelperApps() {
        XCTAssertFalse(ProtectedPaths.isUninstallableApp(
            "/Applications/Vendor.app/Contents/Library/LoginItems/Helper.app",
            bundleID: "com.vendor.helper"))
    }

    func testUninstallRefusesAnythingThatIsNotAnAppBundle() {
        XCTAssertFalse(ProtectedPaths.isUninstallableApp("/Applications/Vendor.app/Contents",
                                                         bundleID: "com.vendor.app"))
        XCTAssertFalse(ProtectedPaths.isUninstallableApp("\(home)/Downloads/installer.dmg"))
    }

    // MARK: - Domain classification

    func testUserDomainCoversTheHomeTreeOnly() {
        XCTAssertTrue(ProtectedPaths.isUserDomain(home))
        XCTAssertTrue(ProtectedPaths.isUserDomain("\(home)/Library/Caches"))
        XCTAssertFalse(ProtectedPaths.isUserDomain("/Library/Caches"))
        XCTAssertFalse(ProtectedPaths.isUserDomain("/System/Library"))
    }
}
