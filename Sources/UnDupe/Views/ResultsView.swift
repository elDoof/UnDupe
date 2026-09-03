import SwiftUI
import UnDupeCore

/// The results screen: breadcrumb + Map/Duplicates switch, with the sunburst and
/// an inspector side by side.
struct ResultsView: View {
    @EnvironmentObject var model: AppModel

    @State private var focusNode: FileNode?
    @State private var hovered: FileNode?
    @State private var selectedNode: FileNode?
    /// Set when the user asks to trash something; drives the confirmation dialog.
    @State private var pendingTrash: FileNode?
    @State private var tab: Tab = .map
    /// Which disk-map visualization is drawn. Persisted so the choice survives
    /// relaunches — it's a taste preference, not per-scan state.
    @AppStorage("mapStyle") private var mapStyle: MapStyle = .treemap

    enum Tab: String, CaseIterable { case map = "Map", duplicates = "Duplicates" }

    /// The two ways of drawing the same tree. `TreemapView` and `SunburstView`
    /// take an identical binding surface, so switching is a pure view swap.
    enum MapStyle: String, CaseIterable {
        case treemap, sunburst

        var symbol: String {
            switch self {
            case .treemap: return "square.grid.2x2"
            case .sunburst: return "circle.circle"
            }
        }

        var label: String {
            switch self {
            case .treemap: return "Treemap — area is size, nested by folder"
            case .sunburst: return "Sunburst — radial rings by folder depth"
            }
        }
    }

    var body: some View {
        if let root = model.selectedRoot {
            VStack(spacing: 0) {
                toolbar(root: root)
                Divider().overlay(Theme.hairline)
                if tab == .map {
                    mapLayout(root: root)
                } else {
                    DuplicatesView()
                }
            }
            .overlay(alignment: .bottom) { statusToast }
        } else {
            Color.clear.onAppear { model.reset() }
        }
    }

    // MARK: - Toolbar

    private func toolbar(root: FileNode) -> some View {
        HStack(spacing: 14) {
            Button { model.reset() } label: {
                Label("New Scan", systemImage: "arrow.left")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
            .hoverHighlight(cornerRadius: 8)
            .help("Discard these results and scan something else")
            .fixedSize()
            .layoutPriority(1) // never compressed or pushed off-screen

            // A deep path can be long; let it scroll within its own space instead
            // of pushing the back button or the tab picker out of the window.
            ScrollView(.horizontal, showsIndicators: false) {
                breadcrumb(root: root)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab == .duplicates && !model.duplicates.isEmpty
                         ? "Duplicates (\(model.duplicates.count))"
                         : tab.rawValue)
                    .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .fixedSize()
            .layoutPriority(1) // keep the tab switch fully visible
            .onChange(of: tab) { newTab in
                if newTab == .duplicates && model.duplicates.isEmpty && !model.isFindingDuplicates {
                    model.findDuplicates()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func breadcrumb(root: FileNode) -> some View {
        let trail = ancestry(of: focusNode ?? root, root: root)
        return HStack(spacing: 4) {
            ForEach(Array(trail.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Button(node.name) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { focusNode = node }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: index == trail.count - 1 ? .semibold : .regular))
                .foregroundStyle(index == trail.count - 1 ? Theme.primaryText : Theme.secondaryText)
            }
        }
    }

    // MARK: - Map + inspector

    private func mapLayout(root: FileNode) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                mapChrome(root: root)
                mapCanvas(root: root)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Theme.hairline)

            InspectorPanel(
                node: hovered ?? selectedNode ?? focusNode ?? root,
                onOpen: { node in
                    if node.isDirectory, !node.children.isEmpty {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { focusNode = node }
                    }
                },
                onSelect: { selectedNode = $0 },
                onReveal: { FileActions.reveal($0.path) },
                onQuickLook: { FileActions.quickLook($0.path) },
                onTrash: { pendingTrash = $0 }
            )
            .frame(width: 320)
        }
        .focusedSceneValue(\.mapActions, mapActions(root: root))
        .confirmationDialog(
            pendingTrash.map { "Move “\($0.name)” to Trash?" } ?? "",
            isPresented: Binding(get: { pendingTrash != nil },
                                 set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { node in
            Button("Move to Trash", role: .destructive) { confirmTrash(node) }
            Button("Cancel", role: .cancel) {}
        } message: { node in
            Text(trashPrompt(for: node))
        }
    }

    /// Strip above the map: the zoom-out affordance, what the map is currently
    /// showing, and the visualization switch. Shared by both styles so the
    /// treemap gets the same "go up" control the sunburst's hub provides.
    private func mapChrome(root: FileNode) -> some View {
        let focus = focusNode ?? root
        let canGoUp = focus !== root && focus.parent != nil

        return HStack(spacing: 10) {
            Button {
                guard let parent = focus.parent else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { focusNode = parent }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(canGoUp ? Theme.secondaryText : Theme.tertiaryText.opacity(0.35))
            .disabled(!canGoUp)
            .help("Go up to the enclosing folder")

            Text(focus.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(ByteFormat.string(focus.size))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent)
            Text("\(focus.fileCount) files")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)

            if !model.hasFullDiskAccess {
                // The map is drawn from what the scan could actually read, so
                // without the grant these totals are understated, not wrong-ish.
                Label("Totals incomplete", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.danger.opacity(0.14)))
                    .help("UnDupe lacks Full Disk Access, so protected folders were skipped. Grant it in System Settings ▸ Privacy & Security.")
                    .fixedSize()
            }

            Spacer(minLength: 12)

            Picker("", selection: $mapStyle) {
                ForEach(MapStyle.allCases, id: \.self) { style in
                    Image(systemName: style.symbol).help(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 92)
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func mapCanvas(root: FileNode) -> some View {
        let focus = Binding(get: { focusNode ?? root }, set: { focusNode = $0 })
        switch mapStyle {
        case .treemap:
            TreemapView(root: root, focus: focus, hovered: $hovered,
                        selected: $selectedNode, onTrash: { pendingTrash = $0 })
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        case .sunburst:
            SunburstView(root: root, focus: focus, hovered: $hovered,
                         selected: $selectedNode, onTrash: { pendingTrash = $0 })
                .padding(24)
        }
    }

    /// Moves `node` to the Trash and tidies up focus/selection so the views don't
    /// point at a detached node.
    private func confirmTrash(_ node: FileNode) {
        if focusNode === node { focusNode = node.parent }
        if selectedNode === node { selectedNode = nil }
        if hovered === node { hovered = nil }
        model.trash([node])
    }

    private func trashPrompt(for node: FileNode) -> String {
        if node.isDirectory {
            return "\(ByteFormat.string(node.size)) · \(node.fileCount) files. The whole folder moves to the Trash — you can restore it from there."
        }
        return "\(ByteFormat.string(node.size)). You can restore it from the Trash."
    }

    /// How long the status toast lingers before it auto-dismisses.
    private static let statusToastDuration: Duration = .seconds(3.5)

    private var statusToast: some View {
        Group {
            if let message = model.statusMessage {
                HStack(spacing: 12) {
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.primaryText)

                    if model.canUndoTrash {
                        Button("Undo") { model.undoLastTrash() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().fill(Theme.success.opacity(0.25)))
                .overlay(Capsule().stroke(Theme.success.opacity(0.5), lineWidth: 1))
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                // Re-armed whenever the message or the undo offer changes.
                .task(id: "\(message)|\(model.canUndoTrash)") {
                    // The toast is the only place Undo lives, so while it is on
                    // offer the toast stays put rather than timing out from
                    // under the user.
                    guard !model.canUndoTrash else { return }
                    do { try await Task.sleep(for: Self.statusToastDuration) } catch { return }
                    withAnimation { model.statusMessage = nil }
                }
            }
        }
        .animation(.easeInOut, value: model.statusMessage)
        .animation(.easeInOut, value: model.canUndoTrash)
    }

    // MARK: - Helpers

    private func ancestry(of node: FileNode, root: FileNode) -> [FileNode] {
        var chain: [FileNode] = []
        var current: FileNode? = node
        while let n = current {
            chain.append(n)
            if n === root { break }
            current = n.parent
        }
        return chain.reversed()
    }

    /// What the menu bar's Item menu acts on: the same node the inspector is
    /// showing, so the menu and the panel can never disagree.
    private func actionTarget(root: FileNode) -> FileNode {
        hovered ?? selectedNode ?? focusNode ?? root
    }

    /// Publishes the map screen's actions to `AppCommands`. Commands live outside
    /// the view hierarchy and can't read this view's `@State`, so they are handed
    /// across as closures; the menu items grey out on other screens because the
    /// focused value is absent there.
    private func mapActions(root: FileNode) -> MapActions {
        let target = actionTarget(root: root)
        let focus = focusNode ?? root
        return MapActions(
            targetName: target.name,
            quickLook: { FileActions.quickLook(target.path) },
            open: { FileActions.open(target.path) },
            reveal: { FileActions.reveal(target.path) },
            copyPath: { FileActions.copyPath(target.path) },
            trash: ProtectedPaths.isDeletable(target.path) ? { pendingTrash = target } : nil,
            goUp: focus !== root ? focus.parent.map { parent in
                { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { focusNode = parent } }
            } : nil
        )
    }
}

// MARK: - Inspector

/// Right-hand details panel for the hovered/focused node.
private struct InspectorPanel: View {
    let node: FileNode
    let onOpen: (FileNode) -> Void
    let onSelect: (FileNode) -> Void
    let onReveal: (FileNode) -> Void
    let onQuickLook: (FileNode) -> Void
    let onTrash: (FileNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                        .foregroundStyle(Theme.accent)
                    Text(node.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(2)
                }
                Text(node.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            HStack(spacing: 18) {
                stat(ByteFormat.string(node.size), "size")
                if node.isDirectory { stat("\(node.fileCount)", "files") }
            }

            HStack(spacing: 10) {
                Button { onReveal(node) } label: { Label("Reveal", systemImage: "magnifyingglass") }
                    .buttonStyle(.bordered)
                Button { onQuickLook(node) } label: { Label("Preview", systemImage: "eye") }
                    .buttonStyle(.bordered)
                    .help("Preview with Quick Look")
                Button(role: .destructive) { onTrash(node) } label: {
                    Label(node.isDirectory ? "Trash Folder" : "Trash", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(Theme.danger)
                .disabled(!ProtectedPaths.isDeletable(node.path))
                .help(ProtectedPaths.refusalReason(node.path) ?? "Move this item to the Trash")
            }
            .controlSize(.small)
            .contextMenu { menu(for: node) }

            if node.isDirectory && !node.children.isEmpty {
                Divider().overlay(Theme.hairline)
                Text("LARGEST ITEMS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(node.children.prefix(12)) { child in
                            childRow(child)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.windowBackground)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.primaryText)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private func childRow(_ child: FileNode) -> some View {
        let fraction = child.fraction(of: node.size)
        return HStack(spacing: 6) {
            Button {
                // Pin the inspector to this child; a non-empty folder also zooms in.
                onSelect(child)
                if child.isDirectory, !child.children.isEmpty { onOpen(child) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: child.isDirectory ? "folder" : "doc")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(child.name)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.primaryText)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(ByteFormat.string(child.size))
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.hairline)
                                Capsule().fill(Theme.accent.opacity(0.7))
                                    .frame(width: max(2, geo.size.width * fraction))
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(role: .destructive) { onTrash(child) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
            }
            .buttonStyle(.plain)
            .disabled(!ProtectedPaths.isDeletable(child.path))
            .help(ProtectedPaths.refusalReason(child.path)
                  ?? "Move “\(child.name)” to Trash")
        }
        .hoverHighlight(cornerRadius: 8)
        .contextMenu { menu(for: child) }
    }

    /// The shared right-click menu, so an inspector row offers exactly what a
    /// map tile does.
    private func menu(for node: FileNode) -> some View {
        FileContextMenu(
            path: node.path,
            name: node.name,
            sizeBytes: node.size,
            isDirectory: node.isDirectory,
            onOpenInMap: node.isDirectory && !node.children.isEmpty
                ? { onSelect(node); onOpen(node) }
                : nil,
            onReveal: { onReveal(node) },
            onTrash: { onTrash(node) }
        )
    }
}
