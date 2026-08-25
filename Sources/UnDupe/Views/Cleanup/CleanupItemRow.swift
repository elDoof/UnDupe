import SwiftUI
import AppKit
import UnDupeCore

/// Small color-coded pill showing who owns an item. The whole cleanup UI keys
/// its actionability off this: green = your item (actionable), orange = system
/// (admin, reveal-only), red = Apple (never touched).
struct OwnerBadge: View {
    let owner: ItemOwner

    var body: some View {
        Text(owner.label.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 0.5))
            .foregroundStyle(color)
            .accessibilityLabel("Owner: \(owner.label)")
    }

    private var color: Color {
        switch owner {
        case .apple:  return Theme.danger
        case .system: return Color(red: 1.0, green: 0.72, blue: 0.36)
        case .user:   return Theme.success
        }
    }
}

/// A compact "reveal in Finder" button, reused across cleanup rows.
struct RevealButton: View {
    let path: String

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: {
            Image(systemName: "magnifyingglass").font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondaryText)
        .help("Reveal in Finder")
        .accessibilityLabel("Reveal in Finder")
    }
}
