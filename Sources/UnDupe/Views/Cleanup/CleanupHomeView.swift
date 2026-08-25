import SwiftUI
import UnDupeCore

/// Routes the System Cleanup area: the module grid, or whichever module is open.
struct CleanupRootView: View {
    @EnvironmentObject var cleanup: CleanupModel

    var body: some View {
        Group {
            switch cleanup.activeModule {
            case .none:
                CleanupHomeView()
            case .startup:
                StartupItemsView()
            case .extensions:
                ExtensionsView()
            case .junk:
                JunkView()
            case .uninstaller:
                AppUninstallerView()
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.22), value: cleanup.activeModule)
    }
}

/// The cleanup landing: a dashboard. A hero figure for reclaimable space sits
/// above a row per module, each auto-scanning on entry so its live total is
/// visible before you ever click in.
struct CleanupHomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var cleanup: CleanupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CleanupHeader(title: "System Cleanup", subtitle: "Tidy up safely — nothing leaves without your say-so.") {
                model.showModePicker()
            }

            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    VStack(spacing: 10) {
                        ForEach(CleanupModel.Module.allCases) { module in
                            moduleRow(module)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { cleanup.loadDashboard() }
        .sheet(isPresented: $cleanup.showAutoCleanup) {
            AutoCleanupSheet().environmentObject(cleanup)
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if cleanup.isScanningDashboard {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                }
                Text(cleanup.isScanningDashboard ? "Scanning your Mac…" : "Reclaimable now")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
            }

            Text(ByteFormat.string(cleanup.reclaimableBytes))
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.primaryText)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.4), value: cleanup.reclaimableBytes)

            Text("Safe-to-clear junk and app leftovers. Nothing is removed until you choose.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 10) {
                Button { cleanup.showAutoCleanup = true } label: {
                    Label("Automatic Cleanup", systemImage: "wand.and.sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(cleanup.junkBytes == 0)

                if cleanup.junkBytes > 0 {
                    Button { cleanup.open(.junk) } label: {
                        Label("Review", systemImage: "list.bullet")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .glassPanel(cornerRadius: 18)
    }

    // MARK: - Module row

    private func moduleRow(_ module: CleanupModel.Module) -> some View {
        Button {
            cleanup.open(module)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: module.icon)
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(module.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(module.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                if cleanup.isScanning(module) {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                } else {
                    Text(cleanup.summary(for: module))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel()
            .hoverHighlight(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }
}

/// Shared header for cleanup screens: a back chevron + title block.
struct CleanupHeader: View {
    let title: String
    let subtitle: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.panel))
                    .overlay(Circle().stroke(Theme.panelStroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Back")

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryText)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 40) // clear the macOS traffic-light buttons (hidden title bar)
        .padding(.bottom, 8)
    }
}
