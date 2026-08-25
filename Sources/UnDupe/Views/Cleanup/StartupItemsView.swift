import SwiftUI
import AppKit
import UnDupeCore

/// Startup & background items module. Lists launchd login items / daemons grouped
/// by owner. Only your own (user-domain) items are selectable for a reversible
/// disable or a move-to-Trash removal; Apple and system items are shown for
/// transparency but are reveal-only.
struct StartupItemsView: View {
    @EnvironmentObject var cleanup: CleanupModel

    /// Selected actionable items, keyed by plist path.
    @State private var selected: Set<String> = []
    @State private var confirming: ConfirmKind?

    enum ConfirmKind: Identifiable {
        case disable, remove
        var id: Int { self == .disable ? 0 : 1 }
    }

    var body: some View {
        VStack(spacing: 0) {
            CleanupHeader(
                title: "Startup & Background",
                subtitle: "Login items and background services that launch automatically."
            ) {
                cleanup.closeModule()
            }

            if cleanup.isScanningStartup && cleanup.startupItems.isEmpty {
                CleanupLoadingState(label: "Reading login items…")
            } else {
                content
            }
        }
        .onAppear { if cleanup.startupItems.isEmpty { cleanup.loadStartupItems() } }
        .onChange(of: cleanup.startupItems) { _ in selected.removeAll() }
        .confirmationDialog(
            confirmTitle,
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { kind in
            Button(kind == .remove ? "Move to Trash" : "Disable", role: .destructive) {
                perform(kind)
            }
            Button("Cancel", role: .cancel) {}
        } message: { kind in
            Text(confirmMessage(kind))
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
                    if !actionableItems.isEmpty {
                        section(title: "YOUR LOGIN ITEMS", items: actionableItems, selectable: true)
                    }
                    if !cleanup.disabledStartup.isEmpty {
                        disabledSection
                    }
                    if !revealOnlyItems.isEmpty {
                        section(title: "SYSTEM & APPLE (REVEAL ONLY)", items: revealOnlyItems, selectable: false)
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
            Text("\(actionableItems.count) of yours · \(revealOnlyItems.count) system")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            if !selectedItems.isEmpty {
                Text("\(selectedItems.count) selected")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Button { confirming = .disable } label: {
                Label("Disable", systemImage: "pause.circle")
            }
            .buttonStyle(.bordered)
            .disabled(selectedItems.isEmpty)
            .help("Reversibly turn off the selected items (re-enable any time)")

            Button(role: .destructive) { confirming = .remove } label: {
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

    private func section(title: String, items: [StartupItem], selectable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
            VStack(spacing: 6) {
                ForEach(items) { item in
                    itemRow(item, selectable: selectable)
                }
            }
        }
    }

    private func itemRow(_ item: StartupItem, selectable: Bool) -> some View {
        let isSelected = selected.contains(item.id)
        return HStack(spacing: 10) {
            if selectable {
                Button { toggle(item) } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "Deselect \(item.label)" : "Select \(item.label)")
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    OwnerBadge(owner: item.owner)
                    loadedIndicator(item.isLoaded)
                }
                Text(item.program ?? item.plistPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer()
            Text(item.kind.label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
            RevealButton(path: item.plistPath)
        }
        .padding(10)
        .glassPanel(cornerRadius: 12)
    }

    private func loadedIndicator(_ isLoaded: Bool) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(isLoaded ? Theme.success : Theme.tertiaryText)
                .frame(width: 6, height: 6)
            Text(isLoaded ? "running" : "idle")
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private var disabledSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DISABLED BY UNDUPE")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
            VStack(spacing: 6) {
                ForEach(cleanup.disabledStartup) { item in
                    HStack(spacing: 10) {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondaryText)
                        Text(URL(fileURLWithPath: item.originalPath).lastPathComponent)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { cleanup.enableStartup(item) } label: {
                            Label("Re-enable", systemImage: "play.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .glassPanel(cornerRadius: 12)
                }
            }
        }
    }

    // MARK: - Notes & banners

    private var infoNote: some View {
        CleanupInfoNote {
            VStack(alignment: .leading, spacing: 4) {
                Text("Disabling is reversible — UnDupe just moves the launch file aside and can put it back. \"Move to Trash\" is recoverable from the Trash.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                Button("Open Login Items in System Settings") { openLoginItemsSettings() }
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Derived

    private var actionableItems: [StartupItem] {
        cleanup.startupItems.filter { $0.isActionable }
    }

    private var revealOnlyItems: [StartupItem] {
        cleanup.startupItems.filter { !$0.isActionable }
    }

    private var selectedItems: [StartupItem] {
        actionableItems.filter { selected.contains($0.id) }
    }

    // MARK: - Logic

    private func toggle(_ item: StartupItem) {
        if selected.contains(item.id) { selected.remove(item.id) }
        else { selected.insert(item.id) }
    }

    private var confirmTitle: String {
        confirming == .remove ? "Move login items to Trash?" : "Disable login items?"
    }

    private func confirmMessage(_ kind: ConfirmKind) -> String {
        let count = selectedItems.count
        switch kind {
        case .disable:
            return "\(count) item(s) will be turned off and won't launch at login. You can re-enable them here at any time."
        case .remove:
            return "\(count) item(s) will be moved to the Trash. You can restore them from the Trash until you empty it."
        }
    }

    private func perform(_ kind: ConfirmKind) {
        let items = selectedItems
        switch kind {
        case .disable: cleanup.disableStartup(items)
        case .remove:  cleanup.removeStartup(items)
        }
        selected.removeAll()
    }

    private func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
