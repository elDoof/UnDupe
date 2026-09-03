import SwiftUI
import UnDupeCore

/// The one place the update flow is visible: check, review, install, relaunch.
struct UpdateSheet: View {
    @EnvironmentObject var updates: UpdateModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider().overlay(Theme.hairline)
            content
            Spacer(minLength: 0)
            buttons
        }
        .padding(24)
        .frame(width: 460, height: 340)
        .background(Theme.backgroundGradient)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            AppIcon(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Software Update")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(updates.currentVersion.map { "You have UnDupe \($0)" } ?? "UnDupe")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updates.phase {
        case .idle, .checking:
            status(spinner: true, title: "Checking for updates…", detail: nil)

        case .upToDate(let version):
            status(symbol: "checkmark.circle.fill", tint: Theme.success,
                   title: "You're up to date.",
                   detail: "UnDupe \(version) is the latest version.")

        case .available(let release):
            availableBody(release)

        case .installing:
            status(spinner: true, title: "Installing…",
                   detail: "Downloading and verifying the update. UnDupe will restart when it's done.")

        case .installed:
            status(symbol: "checkmark.circle.fill", tint: Theme.success,
                   title: "Update installed.", detail: "Restarting UnDupe…")

        case .failed(let message):
            status(symbol: "exclamationmark.triangle.fill", tint: Theme.danger,
                   title: "Update failed.", detail: message)
        }
    }

    private func availableBody(_ release: Release) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("UnDupe \(release.version) is available.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(ByteFormat.string(release.assetSize))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
            }

            if release.notes.isEmpty {
                Text("No release notes were provided.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                ScrollView {
                    ReleaseNotes(markdown: release.notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }

            Label("Updates are only installed if they're signed by the same developer certificate as this copy.",
                  systemImage: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func status(
        spinner: Bool = false,
        symbol: String? = nil,
        tint: Color = Theme.accent,
        title: String,
        detail: String?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if spinner {
                ProgressView().controlSize(.small)
            } else if let symbol {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            Button("Release Notes on GitHub") { updates.openReleasesPage() }
                .buttonStyle(.link)
                .font(.system(size: 11))

            Spacer()

            switch updates.phase {
            case .available(let release):
                Button("Skip This Version") { updates.skip(release) }
                    .buttonStyle(.bordered)
                Button("Install and Restart") { updates.install(release) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)

            case .installing, .installed:
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .disabled(true)

            case .failed:
                Button("Download Manually") { updates.openReleasesPage() }
                    .buttonStyle(.bordered)
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

            default:
                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}


/// Renders a release body as something readable.
///
/// GitHub release notes are Markdown, and `Text` only understands the *inline*
/// part of it — a raw `### Heading` or `- item` would otherwise be shown to the
/// user verbatim. This handles the few block constructs that actually appear in
/// a changelog and leaves the rest to SwiftUI's inline parser.
private struct ReleaseNotes: View {

    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    inline(text)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .padding(.top, 4)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(Theme.tertiaryText)
                        inline(text).foregroundStyle(Theme.secondaryText)
                    }
                    .font(.system(size: 12))
                case .paragraph(let text):
                    inline(text)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Inline Markdown (`**bold**`, `` `code` ``, links) via `AttributedString`,
    /// falling back to the raw text if it doesn't parse.
    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }

    private enum Block {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        markdown.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            // A horizontal rule is a separator, not content.
            if line.allSatisfy({ $0 == "-" }) && line.count >= 3 { return nil }

            if line.hasPrefix("#") {
                return .heading(String(line.drop(while: { $0 == "#" || $0 == " " })))
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                return .bullet(String(line.dropFirst(2)))
            }
            return .paragraph(line)
        }
    }
}
