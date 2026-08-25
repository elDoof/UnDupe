import CoreGraphics
import Foundation
import UnDupeCore

/// One drawable rectangle in the treemap.
struct TreemapTile: Identifiable {
    let id: UUID
    let node: FileNode
    let rect: CGRect
    /// 1 = a direct child of the focused folder; deeper tiles nest inside their parent.
    let depth: Int
    let hue: Double
    /// True when this tile's children are drawn inside it. A container is only
    /// hit-testable along its header strip and its padding frame — the interior
    /// belongs to the children stacked on top of it.
    let isContainer: Bool
    /// Strip along the top of a container where its own name/size is drawn.
    /// `.null` when the tile was too small to spare the room.
    let headerRect: CGRect
}

/// Turns a focused `FileNode` into a flat list of nested rectangles whose areas
/// are proportional to size, using the squarified treemap algorithm (Bruls,
/// Huizing & van Wijk 2000). Squarifying matters: naive slice-and-dice produces
/// long thin slivers that are impossible to compare or click, while squarified
/// tiles stay close to square and therefore stay readable and label-able.
///
/// Tiles are emitted parent-before-children (depth-first), so a hit test that
/// walks the list backwards naturally finds the deepest tile under a point.
enum TreemapLayout {

    /// Levels of nesting drawn inside the focused folder. Deeper than this the
    /// tree collapses into solid leaves — more nesting is neither legible nor
    /// clickable at screen resolution.
    static let maxDepth = 4

    /// Rectangles thinner than this (points) are dropped: they'd be invisible
    /// hairlines that only add draw cost and un-clickable hit targets.
    static let minTileSide: CGFloat = 3

    /// A directory smaller than this on its short side is drawn as a solid leaf
    /// instead of being opened up — there is no room for children inside it.
    static let minContainerSide: CGFloat = 34

    /// Padding between a container's edge and the children nested inside it.
    /// This frame is what makes the nesting readable.
    static let childInset: CGFloat = 2

    /// Height of a container's name strip.
    static let headerHeight: CGFloat = 15

    /// A container narrower than this gets no header — the text wouldn't fit.
    static let minHeaderWidth: CGFloat = 46

    static func tiles(for focus: FileNode, in rect: CGRect) -> [TreemapTile] {
        var tiles: [TreemapTile] = []
        layoutChildren(of: focus, depth: 1, in: rect, inheritedHue: nil, into: &tiles)
        return tiles
    }

    /// Returns the deepest tile containing `point`, or nil when the point is on
    /// bare background. Relies on the parent-before-children emission order.
    static func hitTest(_ point: CGPoint, in tiles: [TreemapTile]) -> TreemapTile? {
        tiles.last { $0.rect.contains(point) }
    }

    // MARK: - Recursion

    /// A node paired with the branch hue it inherits, so the hue survives the
    /// reordering that squarifying performs.
    private struct Item {
        let node: FileNode
        let hue: Double
    }

    private static func layoutChildren(
        of parent: FileNode,
        depth: Int,
        in rect: CGRect,
        inheritedHue: Double?,
        into tiles: inout [TreemapTile]
    ) {
        guard rect.width >= minTileSide, rect.height >= minTileSide else { return }

        let children = drawableChildren(of: parent)
        guard !children.isEmpty else { return }

        let items = children.enumerated().map { index, node in
            Item(node: node, hue: inheritedHue ?? Theme.segmentHues[index % Theme.segmentHues.count])
        }

        for (item, tileRect) in squarify(items, in: rect) {
            let opensUp = item.node.isDirectory
                && !item.node.children.isEmpty
                && depth < maxDepth
                && min(tileRect.width, tileRect.height) >= minContainerSide

            let header = headerRect(in: tileRect, opensUp: opensUp)
            tiles.append(
                TreemapTile(
                    id: item.node.id,
                    node: item.node,
                    rect: tileRect,
                    depth: depth,
                    hue: item.hue,
                    isContainer: opensUp,
                    headerRect: header
                )
            )

            guard opensUp else { continue }
            layoutChildren(
                of: item.node,
                depth: depth + 1,
                in: interior(of: tileRect, header: header),
                inheritedHue: item.hue,
                into: &tiles
            )
        }
    }

    /// The children worth drawing inside `node`.
    ///
    /// Zero-size children are dropped: they would claim zero area and only stall
    /// the squarify loop. More importantly this walks *past* any directory whose
    /// content is a single sub-directory, because such a link carries no size
    /// information of its own — every level in `Chrome.app › Contents ›
    /// Frameworks › Chrome Framework.framework` is exactly 1.47 GB. Drawing each
    /// one costs a header strip and a padding frame while telling the user
    /// nothing, so the chain collapses to the first level that actually splits.
    static func drawableChildren(of node: FileNode) -> [FileNode] {
        var current = node
        while true {
            let children = current.children.filter { $0.size > 0 }
            guard children.count == 1,
                  let only = children.first,
                  only.isDirectory,
                  !only.children.isEmpty
            else { return children }
            current = only
        }
    }

    private static func headerRect(in rect: CGRect, opensUp: Bool) -> CGRect {
        let hasRoom = rect.width >= minHeaderWidth
            && rect.height >= headerHeight + minContainerSide * 0.5
        guard opensUp, hasRoom else { return .null }
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight)
    }

    /// The area inside a container that its children get to fill.
    private static func interior(of rect: CGRect, header: CGRect) -> CGRect {
        let top = header.isNull ? rect.minY + childInset : header.maxY
        return CGRect(
            x: rect.minX + childInset,
            y: top,
            width: rect.width - childInset * 2,
            height: rect.maxY - childInset - top
        )
    }

    // MARK: - Squarified layout

    /// Fills `rect` with one rectangle per item, area proportional to size.
    ///
    /// Works strip by strip: it accumulates items into a row along the shorter
    /// side of the free space for as long as adding one more item *improves*
    /// the row's worst aspect ratio, then lays that row down and repeats on
    /// what's left. Items must arrive sorted largest-first (the scan already
    /// sorts them), which is what lets the worst-ratio check look only at the
    /// row's first and newest members.
    private static func squarify(_ items: [Item], in rect: CGRect) -> [(Item, CGRect)] {
        let total = items.reduce(0.0) { $0 + Double($1.node.size) }
        guard total > 0, rect.width >= minTileSide, rect.height >= minTileSide else { return [] }

        var placements: [(Item, CGRect)] = []
        var remaining = items[...]
        var remainingSize = total
        var free = rect

        while !remaining.isEmpty, free.width >= minTileSide, free.height >= minTileSide, remainingSize > 0 {
            let side = Double(min(free.width, free.height))
            // Area (points²) that one byte is worth in what's left of the space.
            let scale = Double(free.width * free.height) / remainingSize

            let row = takeRow(from: &remaining, side: side, scale: scale)
            guard !row.isEmpty else { break }

            let rowSize = row.reduce(0.0) { $0 + Double($1.node.size) }
            // The strip runs across the shorter side so its tiles stay squarish.
            let isHorizontal = free.width <= free.height
            let span = isHorizontal ? free.height : free.width
            let thickness = min(span, CGFloat(rowSize * scale) / CGFloat(side))
            guard thickness >= minTileSide else { break }

            placements.append(contentsOf: place(row, in: free, thickness: thickness,
                                                scale: scale, isHorizontal: isHorizontal))

            free = isHorizontal
                ? CGRect(x: free.minX, y: free.minY + thickness,
                         width: free.width, height: free.height - thickness)
                : CGRect(x: free.minX + thickness, y: free.minY,
                         width: free.width - thickness, height: free.height)
            remainingSize -= rowSize
        }
        return placements
    }

    /// Pulls items off the front of `remaining` for as long as each addition
    /// keeps the row's worst aspect ratio from getting worse.
    private static func takeRow(
        from remaining: inout ArraySlice<Item>,
        side: Double,
        scale: Double
    ) -> [Item] {
        var row: [Item] = []
        var rowSize = 0.0
        var rowWorst = Double.infinity

        while let next = remaining.first {
            let candidateSize = rowSize + Double(next.node.size)
            // Sorted largest-first, so the row's first item is its largest and
            // the incoming one is its smallest.
            let candidateWorst = worstAspect(
                largest: Double(row.first?.node.size ?? next.node.size),
                smallest: Double(next.node.size),
                rowSize: candidateSize,
                side: side,
                scale: scale
            )
            if !row.isEmpty, candidateWorst > rowWorst { break }

            row.append(next)
            remaining = remaining.dropFirst()
            rowSize = candidateSize
            rowWorst = candidateWorst
        }
        return row
    }

    /// Worst (furthest from 1) width:height ratio among a row's tiles.
    private static func worstAspect(
        largest: Double,
        smallest: Double,
        rowSize: Double,
        side: Double,
        scale: Double
    ) -> Double {
        let rowArea = rowSize * scale
        let largestArea = largest * scale
        let smallestArea = smallest * scale
        guard rowArea > 0, side > 0, smallestArea > 0 else { return .infinity }

        let sideSquared = side * side
        let areaSquared = rowArea * rowArea
        return max(sideSquared * largestArea / areaSquared,
                   areaSquared / (sideSquared * smallestArea))
    }

    /// Lays a finished row along the edge of the free space.
    private static func place(
        _ row: [Item],
        in free: CGRect,
        thickness: CGFloat,
        scale: Double,
        isHorizontal: Bool
    ) -> [(Item, CGRect)] {
        var placements: [(Item, CGRect)] = []
        var cursor = isHorizontal ? free.minX : free.minY

        for item in row {
            let length = CGFloat(Double(item.node.size) * scale) / thickness
            let tileRect = isHorizontal
                ? CGRect(x: cursor, y: free.minY, width: length, height: thickness)
                : CGRect(x: free.minX, y: cursor, width: thickness, height: length)
            if tileRect.width >= minTileSide, tileRect.height >= minTileSide {
                placements.append((item, tileRect))
            }
            cursor += length
        }
        return placements
    }
}
