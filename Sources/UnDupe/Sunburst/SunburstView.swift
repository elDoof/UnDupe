import SwiftUI
import UnDupeCore

/// The interactive radial map. A fresh take on the classic sunburst: a glassy
/// center hub showing the focused folder, concentric rings sized by disk usage,
/// hover-to-highlight, and click-to-zoom into any folder.
struct SunburstView: View {

    let root: FileNode
    /// The folder at the center. Owned by the parent so it can show a breadcrumb.
    @Binding var focus: FileNode
    /// The arc currently under the cursor, surfaced in the inspector.
    @Binding var hovered: FileNode?
    /// The arc the user last clicked. Sticky (unlike `hovered`) so the inspector
    /// stays put on it while the cursor moves to the action buttons.
    @Binding var selected: FileNode?
    /// Asks the host to confirm and trash a node, so deletion keeps going through
    /// the one confirmation dialog `ResultsView` owns.
    let onTrash: (FileNode) -> Void

    @State private var arcs: [SunburstArc] = []
    /// The arc a right-click will act on. Tracks the cursor like `hovered`, but
    /// is deliberately *not* cleared when the pointer leaves: while a context
    /// menu is open the pointer has already left the canvas.
    @State private var contextTarget: FileNode?

    /// Fraction of the radius used by the center hub.
    private let hubRatio: CGFloat = 0.24
    /// Gap between rings, in points.
    private let ringGap: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let metrics = Metrics(size: geo.size, hubRatio: hubRatio)

            ZStack {
                Canvas { context, _ in
                    draw(in: context, metrics: metrics)
                }
                .id(focus.id)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))

                hub(metrics: metrics)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let hit = hitTest(location, metrics: metrics)?.node
                    hovered = hit
                    if let hit { contextTarget = hit }
                case .ended:
                    hovered = nil
                }
            }
            .gesture(
                SpatialTapGesture().onEnded { event in
                    handleTap(at: event.location, metrics: metrics)
                }
            )
            .contextMenu { contextMenu }
        }
        .onAppear { recomputeArcs() }
        // Zooming replaces every arc; see `TreemapView` for why the stale
        // right-click target has to go with them.
        .onChange(of: focus.id) { _ in
            recomputeArcs()
            contextTarget = nil
        }
    }

    // MARK: - Drawing

    private func draw(in context: GraphicsContext, metrics: Metrics) {
        for arc in arcs {
            let inner = metrics.innerRadius(depth: arc.depth)
            let outer = inner + metrics.ringThickness - ringGap
            let path = ringSegment(
                center: metrics.center, innerR: inner, outerR: outer,
                start: arc.startAngle, end: arc.endAngle
            )
            let isHot = hovered?.id == arc.node.id
            context.fill(path, with: .color(Theme.arcColor(hue: arc.hue, depth: arc.depth, highlighted: isHot)))
            if isHot {
                context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
            }
        }
    }

    private func hub(metrics: Metrics) -> some View {
        let canGoUp = focus !== root && focus.parent != nil
        return ZStack {
            Circle()
                .fill(Theme.windowBackground)
                .overlay(Circle().stroke(Theme.panelStroke, lineWidth: 1))
                .frame(width: metrics.hubRadius * 2, height: metrics.hubRadius * 2)

            VStack(spacing: 2) {
                if canGoUp {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Text(focus.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ByteFormat.string(focus.size))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                Text("\(focus.fileCount) files")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .frame(width: metrics.hubRadius * 1.7)
        }
        .help(canGoUp ? "Click to go up a level" : focus.path)
    }

    // MARK: - Interaction

    /// The right-click menu for the arc under the cursor. Mirrors `TreemapView`'s
    /// — the two map styles are meant to be interchangeable.
    @ViewBuilder
    private var contextMenu: some View {
        if let node = contextTarget {
            FileContextMenu(
                path: node.path,
                name: node.name,
                sizeBytes: node.size,
                isDirectory: node.isDirectory,
                // Acting from the menu also pins the inspector to that node, so
                // the panel and the menu never disagree about the subject. Done
                // per action rather than when the menu appears: mutating shared
                // state while the menu's body is being built trips SwiftUI's
                // "modifying state during view update" warning.
                onOpenInMap: node.isDirectory && !node.children.isEmpty
                    ? { selected = node; zoom(into: node) }
                    : nil,
                onReveal: { selected = node; FileActions.reveal(node.path) },
                onTrash: { selected = node; onTrash(node) }
            )
        }
    }

    private func handleTap(at point: CGPoint, metrics: Metrics) {
        let dx = point.x - metrics.center.x
        let dy = point.y - metrics.center.y
        let distance = hypot(dx, dy)

        // Tap on the hub => zoom out one level.
        if distance < metrics.hubRadius {
            if focus !== root, let parent = focus.parent {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { focus = parent }
            }
            return
        }

        // Tap on any arc selects it (pins the inspector); a non-empty folder also
        // zooms in.
        guard let arc = hitTest(point, metrics: metrics) else { return }
        selected = arc.node
        if arc.node.isDirectory, !arc.node.children.isEmpty {
            zoom(into: arc.node)
        }
    }

    private func zoom(into node: FileNode) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { focus = node }
    }

    private func hitTest(_ point: CGPoint, metrics: Metrics) -> SunburstArc? {
        let dx = point.x - metrics.center.x
        let dy = point.y - metrics.center.y
        let distance = hypot(dx, dy)
        guard distance >= metrics.hubRadius, distance <= metrics.maxRadius else { return nil }

        let depth = Int((distance - metrics.hubRadius) / metrics.ringThickness) + 1
        var theta = atan2(dy, dx)
        let start = -Double.pi / 2
        if theta < start { theta += 2 * .pi }

        return arcs.first { $0.depth == depth && theta >= $0.startAngle && theta < $0.endAngle }
    }

    private func recomputeArcs() {
        arcs = SunburstLayout.arcs(for: focus)
    }

    // MARK: - Geometry helpers

    private struct Metrics {
        let center: CGPoint
        let maxRadius: CGFloat
        let hubRadius: CGFloat
        let ringThickness: CGFloat

        init(size: CGSize, hubRatio: CGFloat) {
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            maxRadius = min(size.width, size.height) / 2 - 8
            hubRadius = maxRadius * hubRatio
            ringThickness = (maxRadius - hubRadius) / CGFloat(SunburstLayout.maxDepth)
        }

        func innerRadius(depth: Int) -> CGFloat {
            hubRadius + CGFloat(depth - 1) * ringThickness
        }
    }

    /// Builds a filled ring-segment path between two radii and two angles.
    /// Angle convention: 0 = +x axis, increasing angle sweeps clockwise on screen
    /// (y-down), starting from straight up at -π/2.
    private func ringSegment(center: CGPoint, innerR: CGFloat, outerR: CGFloat, start: Double, end: Double) -> Path {
        var path = Path()
        let s = Angle(radians: start)
        let e = Angle(radians: end)
        path.addArc(center: center, radius: outerR, startAngle: s, endAngle: e, clockwise: false)
        path.addArc(center: center, radius: innerR, startAngle: e, endAngle: s, clockwise: true)
        path.closeSubpath()
        return path
    }
}
