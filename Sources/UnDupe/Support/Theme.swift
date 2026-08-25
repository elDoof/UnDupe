import SwiftUI
import AppKit

/// Visual language for UnDupe: a clean, modern, slightly glassy dark aesthetic
/// with a vivid but legible palette for the sunburst.
enum Theme {

    // MARK: Surfaces

    static let windowBackground = Color(red: 0.07, green: 0.08, blue: 0.10)
    static let panel = Color.white.opacity(0.05)
    static let panelStroke = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.06)

    /// Subtle top-lit gradient used behind every screen for a sense of depth,
    /// echoing the app icon's backdrop.
    static let backgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.10, green: 0.12, blue: 0.17),
            Color(red: 0.05, green: 0.06, blue: 0.08),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: Text

    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.55)
    static let tertiaryText = Color.white.opacity(0.35)

    // MARK: Accent

    static let accent = Color(red: 0.36, green: 0.78, blue: 1.0)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let success = Color(red: 0.40, green: 0.86, blue: 0.58)

    /// Evenly-spaced base hues assigned to top-level segments. Descendants derive
    /// their color from the hue of their top-level ancestor.
    static let segmentHues: [Double] = [
        0.58, 0.72, 0.86, 0.04, 0.10,
        0.14, 0.30, 0.45, 0.92, 0.50,
    ]

    /// Color for a sunburst arc given the hue of its branch and its depth.
    /// Deeper rings get lighter and slightly desaturated for a sense of depth.
    static func arcColor(hue: Double, depth: Int, highlighted: Bool) -> Color {
        let saturation = max(0.30, 0.78 - Double(depth) * 0.10)
        let brightness = min(0.98, 0.72 + Double(depth) * 0.06)
        let base = Color(hue: hue, saturation: saturation, brightness: brightness)
        return highlighted ? base.opacity(1.0) : base.opacity(0.92)
    }

    /// Color for a treemap tile given the hue of its branch and its nesting
    /// depth. Runs dark-to-light with depth so nested folders read as stacked
    /// *on top of* their parent rather than beside it.
    static func tileColor(hue: Double, depth: Int, highlighted: Bool) -> Color {
        let saturation = max(0.26, 0.80 - Double(depth) * 0.11)
        let brightness = min(0.94, 0.50 + Double(depth) * 0.11)
        let base = Color(hue: hue, saturation: saturation, brightness: brightness)
        return highlighted ? base.opacity(1.0) : base.opacity(0.94)
    }

    /// Label color for a treemap tile. Deep tiles are bright enough that white
    /// text washes out, so they flip to dark ink.
    static func tileLabelColor(depth: Int) -> Color {
        depth >= 3 ? Color.black.opacity(0.75) : Color.white.opacity(0.94)
    }
}

/// A reusable rounded "glass" panel background.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.panelStroke, lineWidth: 1)
            )
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }
}

/// Lifts and outlines a row while the pointer is over it. Drives the cursor to a
/// pointing hand so clickable rows feel alive.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 14
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.04 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.accent.opacity(isHovering ? 0.45 : 0), lineWidth: 1)
            )
            .scaleEffect(isHovering ? 1.012 : 1)
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

extension View {
    /// Adds a subtle hover lift + accent outline to a clickable row.
    func hoverHighlight(cornerRadius: CGFloat = 14) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}
