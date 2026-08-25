import SwiftUI

/// Shared building blocks for the System Cleanup screens. Extracted so every
/// module (Startup, Extensions, Junk, Uninstaller) and the dashboard look and
/// behave identically — one place to evolve the cleanup visual language.

// MARK: - Loading

/// Centered spinner + label, shown while a module's first scan runs.
struct CleanupLoadingState: View {
    let label: String

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().scaleEffect(1.2).tint(Theme.accent)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Empty

/// Centered icon + title + message, shown when a module finds nothing to do.
struct CleanupEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var tint: Color = Theme.success

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Status banner

/// One-shot success banner shown after an action, with a dismiss button.
struct CleanupStatusBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.success.opacity(0.12)))
    }
}

// MARK: - Info note

/// Subtle hairline note for the "what's safe / how this works" explainers that
/// sit atop the Startup and Extensions lists.
struct CleanupInfoNote<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.secondaryText)
            content
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.hairline))
    }
}

// MARK: - Section label

/// Uppercase tertiary label that heads a group of rows.
struct CleanupSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Theme.tertiaryText)
    }
}
