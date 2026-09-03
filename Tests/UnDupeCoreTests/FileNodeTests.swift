import XCTest
@testable import UnDupeCore

/// `detachFromParent()` and `reattach(to:)` are what keep the disk map honest
/// after a trash without paying for a full re-scan: they walk the ancestor chain
/// adjusting sizes and file counts by hand. If the two ever stop being exact
/// inverses, an undo silently leaves every folder above the restored file
/// reporting the wrong total — a bug that looks like a scanning error and would
/// be very hard to trace back here. These tests pin the symmetry down.
///
/// Fixtures are built by running the real `ScanEngine` over a temp directory,
/// matching `ScanOutcomeTests` and `TreemapLayoutTests`.
final class FileNodeTests: XCTestCase {

    /// Sizes are rounded up to whole allocation blocks by the filesystem, so the
    /// assertions below compare totals to each other rather than to byte counts.
    private static let tree: [String: Int] = [
        "keep/small.bin": 4_000,
        "keep/medium.bin": 40_000,
        "doomed.bin": 400_000,
        "nested/deep/leaf.bin": 8_000,
    ]

    private var directory: URL!
    private var root: FileNode!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UnDupeFileNodeTests-\(UUID().uuidString)")

        for (relative, bytes) in Self.tree {
            let url = directory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x55, count: bytes).write(to: url)
        }
        addTeardownBlock { [directory] in
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }

        let outcome = ScanEngine().scan(rootPath: directory.path) { _ in }
        root = try XCTUnwrap(outcome.tree, "the fixture directory should scan cleanly")
    }

    /// The direct child of `root` named `name`.
    private func child(_ name: String) throws -> FileNode {
        try XCTUnwrap(root.children.first { $0.name == name },
                      "expected a child named \(name); got \(root.children.map(\.name))")
    }

    // MARK: - Detach

    func testDetachingSubtractsFromEveryAncestor() throws {
        let doomed = try child("doomed.bin")
        let rootSize = root.size
        let rootCount = root.fileCount

        doomed.detachFromParent()

        XCTAssertEqual(root.size, rootSize - doomed.size, "the root loses exactly the node's size")
        XCTAssertEqual(root.fileCount, rootCount - 1, "and exactly its file count")
        XCTAssertNil(doomed.parent, "a detached node no longer points at its old parent")
        XCTAssertFalse(root.children.contains { $0 === doomed }, "and is gone from its children")
    }

    func testDetachingWalksTheWholeAncestorChainNotJustTheParent() throws {
        let nested = try child("nested")
        let deep = try XCTUnwrap(nested.children.first { $0.name == "deep" })
        let leaf = try XCTUnwrap(deep.children.first)
        let rootSize = root.size
        let nestedSize = nested.size

        leaf.detachFromParent()

        XCTAssertEqual(deep.size, 0, "the immediate parent drops to empty")
        XCTAssertEqual(nested.size, nestedSize - leaf.size, "the grandparent is adjusted too")
        XCTAssertEqual(root.size, rootSize - leaf.size, "and so is the root, two levels up")
    }

    // MARK: - Reattach

    func testReattachingRestoresEverySizeAndCountItRemoved() throws {
        let doomed = try child("doomed.bin")
        let rootSize = root.size
        let rootCount = root.fileCount
        let childCount = root.children.count

        doomed.detachFromParent()
        doomed.reattach(to: root)

        XCTAssertEqual(root.size, rootSize, "size returns to exactly what it was")
        XCTAssertEqual(root.fileCount, rootCount, "so does the file count")
        XCTAssertEqual(root.children.count, childCount, "the child is back, exactly once")
        XCTAssertTrue(root.children.contains { $0 === doomed }, "and it is the same object")
        XCTAssertTrue(doomed.parent === root, "with its parent link restored")
    }

    func testReattachingRestoresAWholeSubtreeThroughEveryAncestor() throws {
        let nested = try child("nested")
        let deep = try XCTUnwrap(nested.children.first { $0.name == "deep" })
        let rootSize = root.size
        let rootCount = root.fileCount
        let nestedSize = nested.size

        deep.detachFromParent()
        deep.reattach(to: nested)

        XCTAssertEqual(nested.size, nestedSize, "the folder's own total comes back")
        XCTAssertEqual(root.size, rootSize, "and the adjustment unwinds all the way to the root")
        XCTAssertEqual(root.fileCount, rootCount, "including the descendants' file count")
    }

    func testReattachingKeepsChildrenSortedLargestFirst() throws {
        let smallest = try XCTUnwrap(root.children.last, "children are sorted largest-first")

        smallest.detachFromParent()
        smallest.reattach(to: root)

        let sizes = root.children.map(\.size)
        XCTAssertEqual(sizes, sizes.sorted(by: >),
                       "the treemap and LARGEST ITEMS both rely on this ordering")
    }

    func testReattachingAnAttachedNodeIsIgnored() throws {
        let attached = try child("doomed.bin")
        let rootSize = root.size
        let childCount = root.children.count

        attached.reattach(to: root)

        XCTAssertEqual(root.size, rootSize, "a node that never left must not be counted twice")
        XCTAssertEqual(root.children.count, childCount, "and must not appear twice in children")
    }

    func testDetachingARootIsANoOp() {
        let size = root.size

        root.detachFromParent()

        XCTAssertEqual(root.size, size, "a node with no parent has nothing to subtract from")
        XCTAssertNil(root.parent)
    }
}
