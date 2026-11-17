import XCTest
@testable import UnDupeCore

/// The uninstaller builds the paths it will trash out of two strings read from
/// the app's own `Info.plist` — its bundle identifier and its display name. That
/// makes both untrusted input sitting directly upstream of a delete, so these
/// tests pin down that a hostile or merely odd value can never widen what an
/// uninstall removes.
///
/// Every test runs against a scratch "home" so nothing under the real
/// `~/Library` is read or touched.
final class AppUninstallerTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UnDupeUninstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { [home] in
            if let home { try? FileManager.default.removeItem(at: home) }
        }
    }

    /// Creates a small file at `relative` (from the scratch home), making the
    /// folders above it.
    @discardableResult
    private func makeFile(_ relative: String) throws -> String {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("undupe".utf8).write(to: url)
        return url.path
    }

    private func leftoverPaths(bundleID: String?, appName: String) -> Set<String> {
        Set(AppUninstaller.findLeftovers(bundleID: bundleID, appName: appName, home: home.path)
            .map(\.path))
    }

    // MARK: - Ordinary matching

    func testFindsSupportFilesKeyedOnTheBundleIdentifier() throws {
        // Arrange
        let preferences = try makeFile("Library/Preferences/com.vendor.app.plist")
        let cache = try makeFile("Library/Caches/com.vendor.app/data.bin")
        try makeFile("Library/Caches/com.other.app/data.bin")

        // Act
        let found = leftoverPaths(bundleID: "com.vendor.app", appName: "Vendor")

        // Assert
        XCTAssertTrue(found.contains(preferences))
        XCTAssertTrue(found.contains((cache as NSString).deletingLastPathComponent))
        XCTAssertFalse(found.contains { $0.contains("com.other.app") })
    }

    func testFindsTheFolderAnAppNamesByItsTitle() throws {
        try makeFile("Library/Application Support/Vendor/state.db")

        let found = leftoverPaths(bundleID: "com.vendor.app", appName: "Vendor")

        XCTAssertEqual(found, [home.appendingPathComponent("Library/Application Support/Vendor").path])
    }

    // MARK: - Hostile identifiers

    func testAnIdentifierThatClimbsOutOfTheLibraryMatchesNothing() throws {
        // `~/Library/Caches/../../Documents` is the user's Documents folder.
        try makeFile("Documents/thesis.txt")
        try makeFile("Library/Caches/placeholder")

        let found = leftoverPaths(bundleID: "../../Documents", appName: "Vendor")

        XCTAssertTrue(found.isEmpty, "a traversing identifier must match nothing, got \(found)")
    }

    func testAnEmptyDisplayNameDoesNotClaimTheWholeSupportFolder() throws {
        // "\(home)/Library/Application Support/" + "" is the folder itself.
        try makeFile("Library/Application Support/SomeoneElse/state.db")
        try makeFile("Library/Logs/SomeoneElse/run.log")

        let found = leftoverPaths(bundleID: nil, appName: "")

        XCTAssertTrue(found.isEmpty, "an empty name must match nothing, got \(found)")
    }

    func testADisplayNameThatClimbsOutOfTheSupportFolderMatchesNothing() throws {
        try makeFile("Library/Preferences/com.unrelated.plist")

        let found = leftoverPaths(bundleID: nil, appName: "../Preferences")

        XCTAssertTrue(found.isEmpty, "a traversing name must match nothing, got \(found)")
    }

    func testRejectsTokensThatAreNotPlainNames() {
        for token in ["", ".", "..", "a/b", "../x", "/abs", "new\nline", "nul\0byte"] {
            XCTAssertFalse(AppUninstaller.isSafePathToken(token), "\(token.debugDescription) must be refused")
        }
        for token in ["com.vendor.app", "Vendor", "Some App 2", "naïve-app_1"] {
            XCTAssertTrue(AppUninstaller.isSafePathToken(token), "\(token) should be accepted")
        }
    }

    // MARK: - Group containers

    func testMatchesGroupContainersByWholeIdentifierOnly() {
        let id = "com.vendor.app"
        XCTAssertTrue(AppUninstaller.isGroupContainer("com.vendor.app", for: id))
        XCTAssertTrue(AppUninstaller.isGroupContainer("group.com.vendor.app", for: id))
        XCTAssertTrue(AppUninstaller.isGroupContainer("ABCDE12345.com.vendor.app", for: id))

        // A different app whose identifier merely contains this one.
        XCTAssertFalse(AppUninstaller.isGroupContainer("group.com.vendor.application", for: id))
        XCTAssertFalse(AppUninstaller.isGroupContainer("group.com.vendor.app2", for: id))
        XCTAssertFalse(AppUninstaller.isGroupContainer("group.notcom.vendor.app", for: id))

        // A one-word identifier must not claim containers that merely end in it.
        XCTAssertFalse(AppUninstaller.isGroupContainer("group.com.other.bar", for: "bar"))
        XCTAssertTrue(AppUninstaller.isGroupContainer("bar", for: "bar"))
    }

    func testDoesNotSweepUpAnotherAppsGroupContainer() throws {
        try makeFile("Library/Group Containers/group.com.vendor.app/shared.db")
        try makeFile("Library/Group Containers/group.com.vendor.app2/shared.db")

        let found = leftoverPaths(bundleID: "com.vendor.app", appName: "Vendor")

        XCTAssertEqual(found, [home.appendingPathComponent("Library/Group Containers/group.com.vendor.app").path])
    }
}
