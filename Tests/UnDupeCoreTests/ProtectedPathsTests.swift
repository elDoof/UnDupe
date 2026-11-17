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

    func testRefusesSystemConfigurationReachedThroughPrivate() {
        // `standardizingPath` rewrites /private/etc → /etc and /private/var →
        // /var whenever the shorter path exists, which used to slip these past
        // the "/private" prefix entirely.
        for path in ["/private/etc/hosts", "/etc/hosts", "/etc",
                     "/private/var/db/dslocal", "/var/db/dslocal", "/var", "/private/var"] {
            XCTAssertFalse(ProtectedPaths.isDeletable(path), "\(path) must be protected")
        }
    }

    func testRefusesTheRootsEverythingElseHangsFrom() {
        for path in ["/", "/Users", "/Volumes", "/tmp", "/private/tmp", "/var/folders"] {
            XCTAssertFalse(ProtectedPaths.isDeletable(path), "\(path) must be protected")
        }
    }

    func testRefusesAWholeVolumeButNotWhatIsOnIt() {
        XCTAssertFalse(ProtectedPaths.isDeletable("/Volumes/Backup"))
        XCTAssertFalse(ProtectedPaths.isDeletable("/Volumes/Backup/"))
        XCTAssertTrue(ProtectedPaths.isDeletable("/Volumes/Backup/Old Projects"))
    }

    func testRefusesTheUserLibraryAndItsTopLevelFolders() {
        // Trashing ~/Library/Application Support wholesale would take every
        // app's data with it; what the cleanup modules remove sits deeper.
        for path in ["\(home)/Library",
                     "\(home)/Library/Application Support",
                     "\(home)/Library/Preferences",
                     "\(home)/Library/Caches"] {
            XCTAssertFalse(ProtectedPaths.isDeletable(path), "\(path) must be protected")
        }
        XCTAssertTrue(ProtectedPaths.isDeletable("\(home)/Library/Caches/com.example.app"))
        XCTAssertTrue(ProtectedPaths.isDeletable("\(home)/Library/Preferences/com.example.app.plist"))
    }

    func testStillAllowsScratchFilesUnderTheTemporaryRoots() {
        // Per-user temp and cache space lives under /var/folders, and /tmp is
        // scratch by definition — both are the user's to clear.
        XCTAssertTrue(ProtectedPaths.isDeletable("/tmp/build-output.log"))
        XCTAssertTrue(ProtectedPaths.isDeletable("/private/tmp/build-output.log"))
        XCTAssertTrue(ProtectedPaths.isDeletable("/var/folders/ab/xyz/T/scratch.bin"))
        XCTAssertTrue(ProtectedPaths.isDeletable("/private/var/folders/ab/xyz/T/scratch.bin"))
    }

    func testSeesThroughASymlinkedFolderToTheProtectedPlaceBehindIt() throws {
        // `/Volumes/Macintosh HD` is a symlink to `/` on a normal Mac, so a scan
        // started there reports system files under a path no prefix rule matches.
        // A symlink to `/` in a scratch folder reproduces that anywhere.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UnDupeSymlinkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        let link = scratch.appendingPathComponent("BootDisk").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/")

        XCTAssertFalse(ProtectedPaths.isDeletable("\(link)/usr/bin/true"))
        XCTAssertFalse(ProtectedPaths.isDeletable("\(link)/Library/Preferences"))
        XCTAssertFalse(ProtectedPaths.isDeletable("\(link)/System"))
        // The link itself is just a file in a scratch folder: trashing it
        // removes the link, not what it points at.
        XCTAssertTrue(ProtectedPaths.isDeletable(link))
    }

    func testIgnoresLetterCaseBecauseTheFilesystemDoes() {
        // APFS is case-insensitive by default: these are the same places.
        for path in ["/library/Preferences/x.plist", "/SYSTEM/Library", "/users", "/volumes/Backup",
                     "\(home)/Downloads/Thing.APP/Contents/Info.plist",
                     "\(home.uppercased())/Library"] {
            XCTAssertFalse(ProtectedPaths.isDeletable(path), "\(path) must be protected")
        }
        XCTAssertFalse(ProtectedPaths.isUninstallableApp("/Applications/undupe.app"))
    }

    func testRefusesEveryHomeFolderNotJustTheCurrentUsers() {
        XCTAssertFalse(ProtectedPaths.isDeletable("/Users/someone-else"))
        XCTAssertFalse(ProtectedPaths.isDeletable("/Users/Shared"))
        XCTAssertTrue(ProtectedPaths.isDeletable("/Users/Shared/old-installer.dmg"))
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
