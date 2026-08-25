import CoreGraphics
import XCTest
@testable import UnDupe
@testable import UnDupeCore

/// Geometric invariants that `TreemapView`'s drawing and hit-testing depend on.
///
/// `FileNode` can only be produced by the scanner — its initialiser is internal
/// to UnDupeCore — so these tests scan a real temporary directory of known
/// sizes instead of hand-building a fixture. That also exercises the seam
/// between the engine and the layout, which is where a size or sort-order
/// regression would actually show up.
final class TreemapLayoutTests: XCTestCase {

    private let canvas = CGRect(x: 0, y: 0, width: 1000, height: 700)
    /// Float comparisons on laid-out rectangles need a little slack.
    private let epsilon: CGFloat = 0.01

    private var root: FileNode!
    private var tiles: [TreemapTile]!

    /// Deliberately lopsided sizes: one dominant branch, a mid-sized one, and
    /// several small ones, so the squarify loop has to close more than one row.
    private static let tree: [String: Int] = [
        "big/huge.bin": 8_000_000,
        "big/large.bin": 3_000_000,
        "big/nested/a.bin": 1_500_000,
        "big/nested/b.bin": 900_000,
        "big/nested/deep/c.bin": 400_000,
        "medium/m1.bin": 2_000_000,
        "medium/m2.bin": 1_000_000,
        "small/s1.bin": 300_000,
        "small/s2.bin": 120_000,
        "tiny.bin": 4_096,
    ]

    override func setUpWithError() throws {
        // Arrange: a real tree on disk, scanned by the real engine.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("undupe-treemap-\(UUID().uuidString)")
        for (relativePath, bytes) in Self.tree {
            let file = directory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: file)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        root = try XCTUnwrap(ScanEngine().scan(rootPath: directory.path, progress: { _ in }).tree,
                             "the scan engine returned no tree")
        tiles = TreemapLayout.tiles(for: root, in: canvas)
    }

    private var topLevel: [TreemapTile] { tiles.filter { $0.depth == 1 } }
    private var canvasArea: Double { Double(canvas.width * canvas.height) }
    private func area(_ rect: CGRect) -> Double { Double(rect.width * rect.height) }

    // MARK: - Bounds

    /// Anything at or below this share of the canvas is allowed to be dropped as
    /// a sliver (see `TreemapLayout.minTileSide`). 0.5% is a ~59pt square — far
    /// above the threshold, so nothing borderline lands in either test.
    private let sliverShare = 0.005

    func testEveryTopLevelChildWorthSeeingGetsATile() {
        // Slivers are dropped on purpose, so the contract is about what stays.
        let drawn = Set(topLevel.map { ObjectIdentifier($0.node) })
        let notable = root.children.filter { Double($0.size) / Double(root.size) > sliverShare }
        XCTAssertFalse(notable.isEmpty, "fixture produced nothing worth drawing")
        for child in notable {
            XCTAssertTrue(drawn.contains(ObjectIdentifier(child)), "\(child.name) was dropped")
        }
    }

    func testOnlySliversAreDropped() {
        // The flip side: a folder must never vanish just because it sorted late.
        let drawn = Set(topLevel.map { ObjectIdentifier($0.node) })
        for child in root.children where !drawn.contains(ObjectIdentifier(child)) {
            XCTAssertLessThan(Double(child.size) / Double(root.size), sliverShare,
                              "\(child.name) is big enough to draw but was dropped")
        }
    }

    func testEveryTileStaysInsideTheCanvas() {
        // A tile escaping the canvas would paint over the inspector panel.
        let escaped = tiles.filter {
            $0.rect.minX < canvas.minX - epsilon || $0.rect.minY < canvas.minY - epsilon
                || $0.rect.maxX > canvas.maxX + epsilon || $0.rect.maxY > canvas.maxY + epsilon
        }
        XCTAssertTrue(escaped.isEmpty,
                      "\(escaped.count) tile(s) escaped, first: \(escaped.first?.node.name ?? "")")
    }

    func testTopLevelTilesDoNotOverlap() {
        let rects = topLevel.map { $0.rect.insetBy(dx: epsilon, dy: epsilon) }
        for i in rects.indices {
            for j in rects.indices where j > i {
                XCTAssertFalse(rects[i].intersects(rects[j]),
                               "\(topLevel[i].node.name) overlaps \(topLevel[j].node.name)")
            }
        }
    }

    func testTopLevelCoversTheWholeCanvas() {
        // Squarifying should leave no dead space beyond dropped slivers.
        let coverage = topLevel.reduce(0.0) { $0 + area($1.rect) } / canvasArea
        XCTAssertGreaterThan(coverage, 0.98)
        XCTAssertLessThanOrEqual(coverage, 1.001)
    }

    // MARK: - The treemap premise

    func testTileAreaIsProportionalToSize() {
        // If this fails the picture is lying about what is using the disk.
        for tile in topLevel {
            let expected = Double(tile.node.size) / Double(root.size)
            let actual = area(tile.rect) / canvasArea
            XCTAssertEqual(actual, expected, accuracy: 0.005, "\(tile.node.name)")
        }
    }

    func testNotableTilesStaySquarish() {
        // The point of squarifying: slivers are unreadable and unclickable.
        // Genuinely tiny tiles cannot be square at any resolution, so exclude them.
        let notable = topLevel.filter { area($0.rect) / canvasArea > 0.02 }
        XCTAssertFalse(notable.isEmpty, "fixture produced nothing worth measuring")
        for tile in notable {
            let aspect = max(tile.rect.width / tile.rect.height,
                             tile.rect.height / tile.rect.width)
            XCTAssertLessThan(aspect, 6, "\(tile.node.name) is a sliver")
        }
    }

    func testNestedTilesStayInsideTheirParent() {
        for tile in tiles where tile.depth > 1 {
            let parent = tiles.last {
                $0.depth == tile.depth - 1 && $0.rect.contains(tile.rect.origin)
            }
            let parentRect = try? XCTUnwrap(parent, "\(tile.node.name) has no enclosing parent").rect
            XCTAssertTrue(parentRect?.insetBy(dx: -epsilon, dy: -epsilon).contains(tile.rect) ?? false,
                          "\(tile.node.name) spills out of its parent")
        }
    }

    func testDeepTilesAreClampedToMaxDepth() {
        XCTAssertLessThanOrEqual(tiles.map(\.depth).max() ?? 0, TreemapLayout.maxDepth)
    }

    // MARK: - Single-child chain collapse

    /// A chain like `App.app › Contents › Frameworks › X.framework` carries the
    /// same size at every level, so it must cost one header, not four.
    func testCollapsesADirectoryChainThatNeverSplits() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("undupe-chain-\(UUID().uuidString)")
        let leaf = directory.appendingPathComponent("a/b/c/payload.bin")
        try FileManager.default.createDirectory(at: leaf.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(count: 4_000_000).write(to: leaf)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let chainRoot = try XCTUnwrap(ScanEngine().scan(rootPath: directory.path, progress: { _ in }).tree)
        let chainTiles = TreemapLayout.tiles(for: chainRoot, in: canvas)

        XCTAssertEqual(chainTiles.count, 1, "the chain should collapse to the one tile that has a size")
        XCTAssertEqual(chainTiles.first?.node.name, "payload.bin")
    }

    func testStopsCollapsingWhereTheTreeActuallySplits() {
        // "big" holds two files, so it must survive as its own tile.
        let names = Set(topLevel.map(\.node.name))
        XCTAssertTrue(names.contains("big"), "got \(names)")
    }

    func testCollapseSkipsOnlyDirectoriesNeverFiles() throws {
        // A folder holding exactly one *file* must show the file, not vanish.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("undupe-single-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("only.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: 2_000_000).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let node = try XCTUnwrap(ScanEngine().scan(rootPath: directory.path, progress: { _ in }).tree)
        XCTAssertEqual(TreemapLayout.drawableChildren(of: node).map(\.name), ["only.bin"])
    }

    // MARK: - Hit testing

    func testHitTestFindsTheDeepestTileAtALeafCentre() {
        // Clicking a nested file must select the file, not the folder under it.
        for tile in tiles where !tile.isContainer {
            let hit = TreemapLayout.hitTest(CGPoint(x: tile.rect.midX, y: tile.rect.midY), in: tiles)
            XCTAssertTrue(hit?.node === tile.node, "centre of \(tile.node.name) hit the wrong tile")
        }
    }

    func testHeaderStripBelongsToItsOwnContainer() {
        // The header is how a folder stays selectable once its children cover it.
        let headed = tiles.filter { $0.isContainer && !$0.headerRect.isNull }
        XCTAssertFalse(headed.isEmpty, "fixture produced no container headers")
        for tile in headed {
            let point = CGPoint(x: tile.headerRect.midX, y: tile.headerRect.midY)
            XCTAssertTrue(TreemapLayout.hitTest(point, in: tiles)?.node === tile.node,
                          "\(tile.node.name)'s header hit something else")
        }
    }

    func testHitTestMissesOutsideTheCanvas() {
        XCTAssertNil(TreemapLayout.hitTest(CGPoint(x: -10, y: -10), in: tiles))
    }

    // MARK: - Degenerate input

    func testEmptyRectYieldsNoTiles() {
        XCTAssertTrue(TreemapLayout.tiles(for: root, in: .zero).isEmpty)
    }

    func testSubPixelRectYieldsNoTiles() {
        let sliver = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertTrue(TreemapLayout.tiles(for: root, in: sliver).isEmpty)
    }

    func testFileLeafHasNoChildrenToLayOut() {
        let leaf = try? XCTUnwrap(root.allFiles().first)
        XCTAssertTrue(TreemapLayout.tiles(for: leaf!, in: canvas).isEmpty)
    }
}
