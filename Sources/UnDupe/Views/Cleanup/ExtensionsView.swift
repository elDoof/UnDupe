import SwiftUI
import AppKit
import UnDupeCore

/// Extensions module. App extensions can be toggled on/off (reversible, via
/// pluginkit); directory plugins (Quick Look, Spotlight, Preference Panes…) can
/// be moved to the Trash when they're your own. Apple/system items are reveal-only.
struct ExtensionsView: View {
    @EnvironmentObject var cleanup: CleanupModel

    /// Directory plugins selected for removal, keyed by path.
    @State private var selected: Set<String> = []
    @State private var confirmingRemove = false

    var body: some View {
        VStack(spacing: 0) {
            CleanupHeader(
                title: "Extensions",
                subtitle: "Browser, Finder, Spotlight & system plugins."
            ) {
                cleanup.closeModule()
            }

            if cleanup.isScanningExtensions && cleanup.extensions.isEmpty {
                CleanupLoadingState(label: "Reading extensions…")
            } else {
                content
            }
        }
        .onAppear { if cleanup.extensions.isEmpty { cleanup.loadExtensions() } }
        .onChange(of: cleanup.extensions) { _ in selected.removeAll() }
        .confirmationDialog(
            "Move plugins to Trash?",
            isPresented: $confirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { performRemove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selectedItems.count) plugin(s) will be moved to the Trash. You can restore them until you empty it.")
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            actionBar
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let message = cleanup.statusMessage {
                        CleanupStatusBanner(message: message) { cleanup.statusMessage = nil }
                    }
                    infoNote
                    ForEach(orderedKinds, id: \.self) { kind in
                        section(kind)
                    }
                    if orderedKinds.isEmpty {
                        emptyNote
                    }
                }
                .padding(20)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Text(extensionsCountLabel)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            if !selectedItems.isEmpty {
                Text("\(selectedItems.count) selected · \(ByteFormat.string(selectedBytes))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Button(role: .destructive) { confirmingRemove = true } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.danger)
            .disabled(selectedItems.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Sections

    private func section(_ kind: SystemExtension.Kind) -> some View {
        let items = grouped[kind] ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Text(kind.label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
            VStack(spacing: 6) {
                ForEach(items) { ext in
                    row(ext)
                }
            }
        }
    }

    private func row(_ ext: SystemExtension) -> some View {
        HStack(spacing: 10) {
            leadingControl(ext)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ext.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    OwnerBadge(owner: ext.owner)
                    if ext.kind.isToggleable && ext.state == .disabled {
                        Text("off")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                Text(ext.bundleId ?? ext.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer()
            if ext.sizeBytes > 0 {
                Text(ByteFormat.string(ext.sizeBytes))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            RevealButton(path: ext.path)
        }
        .padding(10)
        .glassPanel(cornerRadius: 12)
    }

    /// App extensions get a switch; removable plugins a checkbox; the rest a lock.
    @ViewBuilder
    private func leadingControl(_ ext: SystemExtension) -> some View {
        if ext.kind.isToggleable {
            Toggle("", isOn: Binding(
                get: { ext.state != .disabled },
                set: { cleanup.toggleExtension(ext, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!ext.canToggle)
            .help(ext.canToggle ? "Enable / disable this extension" : "Apple extension — can't be changed here")
            .accessibilityLabel("\(ext.name) extension, \(ext.state == .disabled ? "off" : "on")")
        } else if ext.canRemove {
            Button { toggleSelection(ext) } label: {
                Image(systemName: selected.contains(ext.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected.contains(ext.id) ? Theme.accent : Theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selected.contains(ext.id) ? "Deselect \(ext.name)" : "Select \(ext.name) for removal")
        } else {
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 16)
        }
    }

    // MARK: - Notes & banners

    private var infoNote: some View {
        CleanupInfoNote {
            Text("App extensions toggle on/off instantly and reversibly. Plugins you own can be moved to the Trash (recoverable). Apple and system items are shown for reference only.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    /// Shown when there's nothing actionable to list (every extension is Apple-
    /// owned and hidden, or none were found) so the screen isn't blank below the
    /// info note.
    private var emptyNote: some View {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 28))
                .foregroundStyle(Theme.tertiaryText)
            Text(hiddenAppleCount > 0
                 ? "Only Apple extensions are installed — nothing to change here."
                 : "No third-party extensions found.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Derived

    /// Apple extensions can't be changed in-app and only add scroll noise, so the
    /// list hides them. The engine still scans them (validation stays honest); we
    /// surface a count so nothing feels secretly omitted.
    private var shownExtensions: [SystemExtension] {
        cleanup.extensions.filter { $0.owner != .apple }
    }

    private var hiddenAppleCount: Int {
        cleanup.extensions.count - shownExtensions.count
    }

    private var extensionsCountLabel: String {
        let base = "\(shownExtensions.count) extensions"
        return hiddenAppleCount > 0 ? "\(base) · \(hiddenAppleCount) Apple hidden" : base
    }

    private var grouped: [SystemExtension.Kind: [SystemExtension]] {
        Dictionary(grouping: shownExtensions, by: { $0.kind })
    }

    private var orderedKinds: [SystemExtension.Kind] {
        SystemExtension.Kind.allCases.filter { grouped[$0]?.isEmpty == false }
    }

    private var selectedItems: [SystemExtension] {
        cleanup.extensions.filter { $0.canRemove && selected.contains($0.id) }
    }

    private var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeBytes }
    }

    // MARK: - Logic

    private func toggleSelection(_ ext: SystemExtension) {
        if selected.contains(ext.id) { selected.remove(ext.id) }
        else { selected.insert(ext.id) }
    }

    private func performRemove() {
        cleanup.removeExtensions(selectedItems)
        selected.removeAll()
    }
}
