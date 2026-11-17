import XCTest
@testable import UnDupeCore

/// The junk scanner is an allowlist, and Automatic Cleanup acts on whatever it
/// marks as safe without the user reviewing individual items — optionally
/// skipping the Trash. These tests pin down which categories earn that trust.
///
/// Runs against a scratch "home" so the real `~/Library` is never read.
final class JunkScannerTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UnDupeJunkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { [home] in
            if let home { try? FileManager.default.removeItem(at: home) }
        }
    }

    private func makeFile(_ relative: String, bytes: Int = 8_192) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private func category(_ name: String, in categories: [JunkCategory]) throws -> JunkCategory {
        try XCTUnwrap(categories.first { $0.name == name },
                      "expected a category named \(name); got \(categories.map(\.name))")
    }

    func testFindsCachesAndLogsAsAutoCleanable() throws {
        // Arrange
        try makeFile("Library/Caches/com.example.app/blob.bin")
        try makeFile("Library/Logs/Example/run.log")

        // Act
        let categories = JunkScanner.scan(home: home.path)

        // Assert
        XCTAssertTrue(try category("User Caches", in: categories).isAutoCleanable)
        XCTAssertTrue(try category("Logs", in: categories).isAutoCleanable)
    }

    func testXcodeArchivesAreListedButNeverAutoCleanable() throws {
        // An archive is a shipped build plus its debug symbols; nothing
        // rebuilds it, so it must not ride along with regenerable junk.
        try makeFile("Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/Info.plist")
        try makeFile("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o")

        let categories = JunkScanner.scan(home: home.path)

        let archives = try category("Xcode Archives", in: categories)
        XCTAssertFalse(archives.isAutoCleanable)
        XCTAssertEqual(archives.items.map(\.name), ["Archives"])

        let developer = try category("Xcode & Developer", in: categories)
        XCTAssertTrue(developer.isAutoCleanable)
        XCTAssertFalse(developer.items.contains { $0.path.hasSuffix("/Archives") },
                       "archives must not also appear among the regenerable items")
    }

    func testEveryReportedItemSitsBeneathTheHomeLibrary() throws {
        try makeFile("Library/Caches/com.example.app/blob.bin")
        try makeFile("Library/Logs/Example/run.log")
        try makeFile("Documents/keep-me.txt")

        let items = JunkScanner.scan(home: home.path).flatMap(\.items)

        XCTAssertFalse(items.isEmpty)
        for item in items {
            XCTAssertTrue(item.path.hasPrefix(home.path + "/Library/"),
                          "\(item.path) is outside the allowlisted Library roots")
        }
    }

    func testAnEmptyHomeYieldsNoCategories() {
        XCTAssertTrue(JunkScanner.scan(home: home.path).isEmpty)
    }
}
