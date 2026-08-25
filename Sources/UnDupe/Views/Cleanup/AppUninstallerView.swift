import SwiftUI
import AppKit
import UnDupeCore

/// App Uninstaller module. Lists installed apps with the leftover support files
/// each one would take down with it. Selection is opt-in; uninstalling moves the
/// bundle *and* its leftovers to the Trash (recoverable). Apple apps are shown for
/// transparency but locked — reveal-only, never uninstalled in-app.
struct AppUninstallerView: View {
    @EnvironmentObject var cleanup: CleanupModel

    /// Apps selected for uninstall, keyed by bundle path.
    @State private var selected: Set<String> = []
    /// Apps whose leftover list is expanded, keyed by bundle path.
    @State private var expanded: Set<String> = []
    /// Leftover paths the user chose to **keep** (everything else is removed).
    @State private var keptLeftovers: Set<String> = []
    @State private var confirmingUninstall = false

    var body: some View {
        VStack(spacing: 0) {
            CleanupHeader(
                title: "App Uninstaller",
                subtitle: "Remove apps and the leftovers they scatter — to the Trash."
            ) {
                cleanup.closeModule()
            }

            if cleanup.isScanningApps && cleanup.installedApps.isEmpty {
                CleanupLoadingState(label: "Finding installed apps…")
            } else if cleanup.installedApps.isEmpty {
                CleanupEmptyState(icon: "checkmark.circle", title: "No apps found", message: "Nothing in your Applications folders to uninstall.")
            } else {
                content
            }
        }
        .onAppear { if cleanup.installedApps.isEmpty { cleanup.loadApps() } }
        .onChange(of: cleanup.installedApps) { _ in
            selected.removeAll()
            expanded.removeAll()
            keptLeftovers.removeAll()
        }
        .confirmationDialog(
            "Move \(selectedApps.count) app(s) to Trash?",
            isPresented: $confirmingUninstall,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { performUninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selectedApps.count) app(s) and \(removedLeftoverCount) support file(s) — \(ByteFormat.string(removedBytes)) — will be moved to the Trash. Unchecked leftovers are kept. You can restore everything until you empty the Trash.")
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            actionBar
            Divider().overlay(Theme.hairline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let message = cleanup.statusMessage {
                        CleanupStatusBanner(message: message) { cleanup.statusMessage = nil }
                    }
                    ForEach(cleanup.installedApps) { app in
                        appRow(app)
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
            VStack(alignment: .leading, spacing: 2) {
                Text("\(uninstallableCount) of \(cleanup.installedApps.count) apps removable")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("Apple apps are locked. Everything else goes to the Trash with its leftovers.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if !selectedApps.isEmpty {
                Text("\(selectedApps.count) selected · \(ByteFormat.string(removedBytes))")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Button(role: .destructive) { confirmingUninstall = true } label: {
                Label("Uninstall", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.danger)
            .disabled(selectedApps.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - App row

    private func appRow(_ app: InstalledApp) -> some View {
        let isSelected = selected.contains(app.id)
        let isExpanded = expanded.contains(app.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if app.canUninstall {
                    Button { toggle(app) } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(isSelected ? Theme.accent : Theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelected ? "Deselect \(app.name)" : "Select \(app.name) for uninstall")
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(width: 16)
                        .help("Apple app — reveal-only, can't be uninstalled here")
                }

                appIcon(app)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                            .lineLimit(1)
                        OwnerBadge(owner: app.owner)
                        if let version = app.version {
                            Text("v\(version)")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                    leftoverSummary(app)
                }

                Spacer()

                Text(ByteFormat.string(app.totalBytes))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                RevealButton(path: app.bundlePath)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)

            if isExpanded && !app.leftovers.isEmpty {
                leftoverList(app)
            }
        }
        .padding(.horizontal, 10)
        .glassPanel(cornerRadius: 12)
    }

    /// App-global icon cache. `NSWorkspace.shared.icon(forFile:)` is synchronous
    /// and was being called from every row's body on each redraw/scroll — janky on
    /// a full Applications folder. Icons are deterministic per bundle path, so we
    /// memoize them. `NSCache` is thread-safe and evicts under memory pressure.
    private static let iconCache = NSCache<NSString, NSImage>()

    private func appIcon(_ app: InstalledApp) -> some View {
        let key = app.bundlePath as NSString
        let image: NSImage
        if let cached = Self.iconCache.object(forKey: key) {
            image = cached
        } else {
            image = NSWorkspace.shared.icon(forFile: app.bundlePath)
            Self.iconCache.setObject(image, forKey: key)
        }
        return Image(nsImage: image)
            .resizable()
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func leftoverSummary(_ app: InstalledApp) -> some View {
        if app.leftovers.isEmpty {
            Text("No leftover files found")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        } else {
            Button { toggleExpanded(app) } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded.contains(app.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(app.leftovers.count) leftover\(app.leftovers.count == 1 ? "" : "s") · \(ByteFormat.string(app.leftoverBytes))")
                        .font(.system(size: 10))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private func leftoverList(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("INCLUDED IN UNINSTALL")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                Text("Uncheck anything you'd like to keep")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.bottom, 2)

            ForEach(app.leftovers) { leftover in
                leftoverRow(leftover)
            }
        }
        .padding(.leading, 54)
        .padding(.trailing, 8)
        .padding(.bottom, 10)
    }

    private func leftoverRow(_ leftover: AppLeftover) -> some View {
        let isRemoved = !keptLeftovers.contains(leftover.path)
        return HStack(spacing: 8) {
            Button { toggleLeftover(leftover) } label: {
                Image(systemName: isRemoved ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isRemoved ? Theme.accent : Theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .help(isRemoved ? "Will be removed — click to keep" : "Will be kept — click to remove")
            .accessibilityLabel("\(leftover.category) leftover, \(isRemoved ? "will be removed, activate to keep" : "will be kept, activate to remove")")

            Text(leftover.category)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isRemoved ? Theme.secondaryText : Theme.tertiaryText)
                .frame(width: 130, alignment: .leading)
            Text(leftover.path)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1).truncationMode(.middle)
                .strikethrough(!isRemoved, color: Theme.tertiaryText)
            Spacer()
            Text(ByteFormat.string(leftover.sizeBytes))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Theme.tertiaryText)
            RevealButton(path: leftover.path)
        }
    }

    // MARK: - Derived

    private var uninstallableCount: Int {
        cleanup.installedApps.filter { $0.canUninstall }.count
    }

    private var selectedApps: [InstalledApp] {
        cleanup.installedApps.filter { selected.contains($0.id) }
    }

    /// Bytes that will actually be freed: each selected app's bundle plus the
    /// leftovers the user hasn't chosen to keep.
    private var removedBytes: Int64 {
        selectedApps.reduce(0) { running, app in
            let leftovers = app.leftovers
                .filter { !keptLeftovers.contains($0.path) }
                .reduce(0) { $0 + $1.sizeBytes }
            return running + app.bundleSizeBytes + leftovers
        }
    }

    /// Count of leftovers across selected apps that will actually be removed.
    private var removedLeftoverCount: Int {
        selectedApps.reduce(0) { running, app in
            running + app.leftovers.filter { !keptLeftovers.contains($0.path) }.count
        }
    }

    // MARK: - Logic

    private func toggle(_ app: InstalledApp) {
        guard app.canUninstall else { return }
        if selected.contains(app.id) { selected.remove(app.id) }
        else { selected.insert(app.id) }
    }

    private func toggleExpanded(_ app: InstalledApp) {
        if expanded.contains(app.id) { expanded.remove(app.id) }
        else { expanded.insert(app.id) }
    }

    private func toggleLeftover(_ leftover: AppLeftover) {
        if keptLeftovers.contains(leftover.path) { keptLeftovers.remove(leftover.path) }
        else { keptLeftovers.insert(leftover.path) }
    }

    private func performUninstall() {
        cleanup.uninstallApps(selectedApps, keepingLeftovers: keptLeftovers)
        selected.removeAll()
    }
}
