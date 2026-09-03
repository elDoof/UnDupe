import SwiftUI
import UnDupeCore

/// The interactive treemap: every folder and file is a rectangle whose *area*
/// is its share of the disk, nested inside its parent. Unlike the sunburst,
/// tiles are wide enough to carry their own name and size, so the map is
/// readable without hovering anything.
///
/// Shares its binding surface with `SunburstView` so `ResultsView` can swap
/// between the two with nothing but a style enum.
struct TreemapView: View {

    let root: FileNode
    /// The folder filling the map. Owned by the parent so it can show a breadcrumb.
    @Binding var focus: FileNode
    /// The tile currently under the cursor, surfaced in the inspector.
    @Binding var hovered: FileNode?
    /// The tile the user last clicked. Sticky (unlike `hovered`) so the inspector
    /// stays put on it while the cursor travels to the action buttons.
    @Binding var selected: FileNode?
    /// Asks the host to confirm and trash a node, so deletion keeps going through
    /// the one confirmation dialog `ResultsView` owns.
    let onTrash: (FileNode) -> Void

    @State private var tiles: [TreemapTile] = []
    @State private var layoutSize: CGSize = .zero
    /// The tile a right-click will act on. Tracks the cursor like `hovered`, but
    /// is deliberately *not* cleared when the pointer leaves: while a context
    /// menu is open the pointer has already left the canvas, and clearing here
    /// would blank the menu the user is reading.
    @State private var contextTarget: FileNode?

    /// Corner rounding of a tile. Small: at treemap densities anything larger
    /// eats visible area and makes neighbouring tiles look detached.
    private let cornerRadius: CGFloat = 2.5
    /// Inset between a leaf tile's edge and its label.
    private let labelPadding: CGFloat = 5
    /// Below this width a tile gets no label at all.
    private let minLabelWidth: CGFloat = 34
    /// Below this height a tile gets no label at all.
    private let minLabelHeight: CGFloat = 13
    /// A leaf this tall can carry its size on a second line under the name.
    private let twoLineHeight: CGFloat = 32
    /// Clear space kept between a one-line name and the size on its right.
    private let labelGap: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            Canvas { context, _ in
                draw(in: context)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let hit = TreemapLayout.hitTest(location, in: tiles)?.node
                    hovered = hit
                    if let hit { contextTarget = hit }
                case .ended:
                    hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { handleTap(at: $0.location) })
            .contextMenu { contextMenu }
            .onAppear { rebuild(size: geo.size) }
            .onChange(of: geo.size) { rebuild(size: $0) }
            // Zooming replaces every tile, so the previous right-click target is
            // no longer on screen; a menu opened before the next mouse move would
            // otherwise act on a tile the user can't see.
            .onChange(of: focus.id) { _ in
                rebuild(size: layoutSize)
                contextTarget = nil
            }
        }
    }

    // MARK: - Layout

    private func rebuild(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        layoutSize = size
        tiles = TreemapLayout.tiles(for: focus, in: CGRect(origin: .zero, size: size))
    }

    // MARK: - Drawing

    private func draw(in context: GraphicsContext) {
        for tile in tiles {
            let path = Path(roundedRect: tile.rect, cornerRadius: cornerRadius)
            let isHot = hovered?.id == tile.node.id

            context.fill(path, with: .color(Theme.tileColor(hue: tile.hue, depth: tile.depth, highlighted: isHot)))
            // A hairline of the background between neighbours; without it a run
            // of same-hue siblings melts into one blob.
            context.stroke(path, with: .color(.black.opacity(0.28)), lineWidth: 0.5)
            if isHot {
                context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
            }
            drawLabel(for: tile, in: context)
        }
    }

    private func drawLabel(for tile: TreemapTile, in context: GraphicsContext) {
        if tile.isContainer {
            guard !tile.headerRect.isNull else { return }
            drawNameAndSize(tile, in: tile.headerRect, context: context, stacked: false)
            return
        }
        guard tile.rect.width >= minLabelWidth, tile.rect.height >= minLabelHeight else { return }
        drawNameAndSize(tile, in: tile.rect, context: context,
                        stacked: tile.rect.height >= twoLineHeight)
    }

    /// Draws "name … size" inside `area`, either on one line (name left, size
    /// right) or stacked. Everything is clipped to `area`, so a long name
    /// truncates at the tile edge instead of bleeding onto its neighbours.
    private func drawNameAndSize(
        _ tile: TreemapTile,
        in area: CGRect,
        context: GraphicsContext,
        stacked: Bool
    ) {
        let ink = Theme.tileLabelColor(depth: tile.depth)
        let name = context.resolve(
            Text(tile.node.name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(ink)
        )
        let size = context.resolve(
            Text(ByteFormat.string(tile.node.size))
                .font(.system(size: 9.5, weight: .regular))
                .foregroundColor(ink.opacity(0.75))
        )
        let sizeWidth = size.measure(in: area.size).width
        let showsSize = area.width >= sizeWidth + minLabelWidth

        if stacked {
            context.drawLayer { layer in
                layer.clip(to: Path(textBox(in: area, width: area.width - labelPadding * 2)))
                layer.draw(name, at: CGPoint(x: area.minX + labelPadding, y: area.minY + labelPadding),
                           anchor: .topLeading)
                layer.draw(size, at: CGPoint(x: area.minX + labelPadding, y: area.minY + labelPadding + 13),
                           anchor: .topLeading)
            }
            return
        }

        // One line: the name gets whatever is left after the size is reserved,
        // and is clipped to exactly that. Without the reservation a long name
        // runs straight through the size on the right.
        let reserved = showsSize ? sizeWidth + labelGap : 0
        context.drawLayer { layer in
            layer.clip(to: Path(textBox(in: area, width: area.width - labelPadding * 2 - reserved)))
            layer.draw(name, at: CGPoint(x: area.minX + labelPadding, y: area.midY), anchor: .leading)
        }
        if showsSize {
            context.draw(size, at: CGPoint(x: area.maxX - labelPadding, y: area.midY), anchor: .trailing)
        }
    }

    /// Clip box for a label: `width` points starting at the label inset.
    private func textBox(in area: CGRect, width: CGFloat) -> CGRect {
        CGRect(x: area.minX + labelPadding, y: area.minY,
               width: max(0, width), height: area.height)
    }

    // MARK: - Interaction

    /// The right-click menu for the tile under the cursor.
    ///
    /// A `Canvas` draws every tile itself, so there is no per-tile view to attach
    /// a menu to; the target is the one the hover hit-test already resolved,
    /// which is by definition the tile the pointer is over. The menu names it in
    /// its header so the user can see what they are about to act on.
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

    private func handleTap(at point: CGPoint) {
        guard let tile = TreemapLayout.hitTest(point, in: tiles) else {
            // Bare background: treat as "zoom out", matching the sunburst hub.
            zoomOut()
            return
        }
        selected = tile.node
        if tile.node.isDirectory, !tile.node.children.isEmpty {
            zoom(into: tile.node)
        }
    }

    private func zoom(into node: FileNode) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { focus = node }
    }

    private func zoomOut() {
        guard focus !== root, let parent = focus.parent else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { focus = parent }
    }
}
