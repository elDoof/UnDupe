import Foundation
import UnDupeCore

/// One drawable ring segment in the sunburst.
struct SunburstArc: Identifiable {
    let id: UUID
    let node: FileNode
    /// 1 = innermost ring (the hub at the center is the focused folder itself).
    let depth: Int
    let startAngle: Double   // radians, 0 = up, clockwise
    let endAngle: Double
    let hue: Double

    var sweep: Double { endAngle - startAngle }
}

/// Turns a focused `FileNode` into a flat list of arcs laid out as concentric
/// rings, each child occupying an angular slice proportional to its size within
/// its parent.
enum SunburstLayout {

    /// Rings drawn outward from the hub. Beyond this depth the tree is collapsed
    /// to keep the picture legible and fast.
    static let maxDepth = 5

    /// Slices narrower than this (radians) are dropped — they'd be invisible
    /// slivers and only add noise/cost. ~0.9°.
    static let minSweep = 0.016

    /// Angle at which the first slice begins (straight up).
    private static let startAngle = -Double.pi / 2

    static func arcs(for focus: FileNode) -> [SunburstArc] {
        var arcs: [SunburstArc] = []
        let total = Double(max(1, focus.size))
        var angle = startAngle

        for (index, child) in focus.children.enumerated() {
            let sweep = Double(child.size) / total * 2 * .pi
            if sweep < minSweep { angle += sweep; continue }
            let hue = Theme.segmentHues[index % Theme.segmentHues.count]
            layout(node: child, depth: 1, start: angle, sweep: sweep, hue: hue, into: &arcs)
            angle += sweep
        }
        return arcs
    }

    private static func layout(
        node: FileNode,
        depth: Int,
        start: Double,
        sweep: Double,
        hue: Double,
        into arcs: inout [SunburstArc]
    ) {
        arcs.append(
            SunburstArc(id: node.id, node: node, depth: depth,
                        startAngle: start, endAngle: start + sweep, hue: hue)
        )

        guard depth < maxDepth, node.isDirectory, node.size > 0 else { return }
        let total = Double(node.size)
        var angle = start
        for child in node.children {
            let childSweep = Double(child.size) / total * sweep
            if childSweep < minSweep { angle += childSweep; continue }
            layout(node: child, depth: depth + 1, start: angle, sweep: childSweep, hue: hue, into: &arcs)
            angle += childSweep
        }
    }
}
