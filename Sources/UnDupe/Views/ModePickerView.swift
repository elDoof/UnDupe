import SwiftUI

/// The first screen: pick what you came to do. UnDupe now covers two jobs —
/// visualizing/clearing disk space (the original flow) and tidying up the system
/// (startup items, extensions, junk, app removal). Each is its own experience.
struct ModePickerView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 10) {
                AppIcon(size: 84)
                Text("UnDupe")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryText)
                Text("Reclaim space and tidy up your Mac — safely.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.top, 56)

            HStack(spacing: 18) {
                modeCard(
                    icon: "chart.pie.fill",
                    title: "Scan Disk",
                    subtitle: "See what's using space and clear duplicates",
                    action: { model.enterDiskMode() }
                )
                modeCard(
                    icon: "wand.and.sparkles",
                    title: "System Cleanup",
                    subtitle: "Startup items, extensions, junk & app removal",
                    action: { model.enterCleanupMode() }
                )
            }
            .frame(maxWidth: 720)

            Spacer()
        }
        .padding(32)
    }

    private func modeCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Theme.accent.opacity(0.14))
                    Image(systemName: icon)
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.accent)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.primaryText)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 5) {
                    Text("Open")
                        .font(.system(size: 12, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .glassPanel()
            .hoverHighlight(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }
}
