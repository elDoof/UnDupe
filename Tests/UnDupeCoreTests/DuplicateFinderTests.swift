import XCTest
@testable import UnDupeCore

/// The duplicate finder's output is a list of files the app will offer to trash
/// under the label "verified byte-for-byte", so a false positive here is a data
/// loss bug rather than a cosmetic one. These tests cover the funnel end to end
/// against real files, including the cases that must *not* match.
///
/// Fixtures are built by running the real `ScanEngine` over a temp directory,
/// matching `FileNodeTests`.
final class DuplicateFinderTests: XCTestCase {

    /// Small enough that the fixtures stay tiny; the 1 MB default is exercised
    /// separately.
    private static let testMinSize: Int64 = 1

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UnDupeDuplicateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { [directory] in
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
    }

    private func write(_ relative: String, _ data: Data) throws {
        let url = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func scan() throws -> FileNode {
        let outcome = ScanEngine().scan(rootPath: directory.path) { _ in }
        return try XCTUnwrap(outcome.tree, "the fixture directory should scan cleanly")
    }

    /// Runs the finder and returns each group as a sorted list of file names.
    private func duplicateNames(minSize: Int64 = testMinSize) throws -> [[String]] {
        let groups = DuplicateFinder().find(in: [try scan()], minSize: minSize) { _ in }
        return groups.map { $0.files.map(\.name).sorted() }.sorted { $0[0] < $1[0] }
    }

    // MARK: - Matching

    func testGroupsFilesWithIdenticalContents() throws {
        // Arrange
        let payload = Data(repeating: 0x11, count: 20_000)
        try write("a/one.bin", payload)
        try write("b/two.bin", payload)
        try write("c/three.bin", payload)
        try write("unique.bin", Data(repeating: 0x22, count: 31_000))

        // Act
        let groups = try duplicateNames()

        // Assert
        XCTAssertEqual(groups, [["one.bin", "three.bin", "two.bin"]])
    }

    func testSameSizeButDifferentContentsIsNotADuplicate() throws {
        try write("first.bin", Data(repeating: 0x11, count: 20_000))
        try write("second.bin", Data(repeating: 0x22, count: 20_000))

        XCTAssertTrue(try duplicateNames().isEmpty)
    }

    func testAMatchingPrefixIsNotEnoughWithoutAMatchingBody() throws {
        // Identical well past the 4 KB prefix probe, different in the last byte:
        // only the full hash can tell these apart.
        var first = Data(repeating: 0x33, count: 50_000)
        var second = first
        first[49_999] = 0x01
        second[49_999] = 0x02
        try write("first.bin", first)
        try write("second.bin", second)

        XCTAssertTrue(try duplicateNames().isEmpty)
    }

    func testHardLinksToOneFileAreNotReportedAsDuplicates() throws {
        // Two names for the same inode: trashing one frees nothing.
        try write("original.bin", Data(repeating: 0x44, count: 20_000))
        let original = directory.appendingPathComponent("original.bin").path
        let linked = directory.appendingPathComponent("linked.bin").path
        XCTAssertEqual(link(original, linked), 0, "couldn't create the hard link fixture")

        XCTAssertTrue(try duplicateNames().isEmpty)
    }

    func testTheDefaultFloorIgnoresSmallFiles() throws {
        let payload = Data(repeating: 0x55, count: 20_000)
        try write("one.bin", payload)
        try write("two.bin", payload)

        XCTAssertTrue(try duplicateNames(minSize: DuplicateFinder.defaultMinSize).isEmpty)
    }

    // MARK: - Unreadable input

    func testAFailedReadYieldsNoHashRatherThanAPartialOne() {
        // Opening a directory for reading succeeds; reading from it fails. A
        // hash of "everything read before the failure" would be the hash of
        // nothing, identical for every such file.
        XCTAssertNil(DuplicateFinder.hash(path: directory.path, maxBytes: nil))
        XCTAssertNil(DuplicateFinder.hash(path: directory.path, maxBytes: 4_096))
    }

    func testAMissingFileYieldsNoHash() {
        let missing = directory.appendingPathComponent("gone.bin").path
        XCTAssertNil(DuplicateFinder.hash(path: missing, maxBytes: nil))
    }

    // MARK: - Cancellation

    func testACancelThatArrivesBeforeTheSearchStartsIsHonoured() throws {
        // The search runs on a background queue, so "cancel" can win the race
        // to it. It must still stop the search rather than be forgotten.
        let payload = Data(repeating: 0x11, count: 20_000)
        try write("one.bin", payload)
        try write("two.bin", payload)
        let root = try scan()
        let finder = DuplicateFinder()

        finder.cancel()
        let groups = finder.find(in: [root], minSize: Self.testMinSize) { _ in }

        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - Progress

    func testProgressFinishesOnItsTotal() throws {
        // Arrange: four same-size candidates, only two of which survive the
        // prefix stage — the others must still count toward the total.
        let payload = Data(repeating: 0x66, count: 20_000)
        try write("dup-a.bin", payload)
        try write("dup-b.bin", payload)
        try write("odd-a.bin", Data(repeating: 0x77, count: 20_000))
        try write("odd-b.bin", Data(repeating: 0x78, count: 20_000))
        let root = try scan()

        let lock = NSLock()
        var reports: [DuplicateFinder.Progress] = []

        // Act
        _ = DuplicateFinder().find(in: [root], minSize: Self.testMinSize) { progress in
            lock.lock(); reports.append(progress); lock.unlock()
        }

        // Assert
        let last = try XCTUnwrap(reports.last, "expected at least one progress report")
        XCTAssertEqual(last.totalToHash, 4)
        XCTAssertEqual(last.filesHashed, last.totalToHash)
        XCTAssertTrue(reports.allSatisfy { $0.filesHashed <= $0.totalToHash })
    }
}
