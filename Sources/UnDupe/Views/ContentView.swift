import SwiftUI
import AppKit
import UnDupeCore

/// Root view: routes between the start screen, the live scan, and the results.
struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Theme.backgroundGradient.ignoresSafeArea()

            Group {
                switch model.topLevel {
                case .picker:
                    ModePickerView()
                case .disk:
                    switch model.phase {
                    case .home:     HomeView()
                    case .scanning: ScanProgressView()
                    case .results:  ResultsView()
                    }
                case .cleanup:
                    CleanupRootView()
                }
            }
            .transition(.opacity)
        }
        .frame(minWidth: 940, minHeight: 660)
        .environment(\.colorScheme, .dark)
        .tint(Theme.accent)
        .animation(.easeInOut(duration: 0.28), value: model.phase)
        .animation(.easeInOut(duration: 0.28), value: model.topLevel)
    }
}

// MARK: - App icon

/// Renders the bundle's real app icon (the generated sunburst) with a soft
/// drop shadow. Falls back to an SF Symbol if the icon can't be loaded.
struct AppIcon: View {
    var size: CGFloat

    var body: some View {
        if let image = NSApp.applicationIconImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.45), radius: size * 0.10, y: size * 0.04)
        } else {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: size * 0.5))
                .foregroundStyle(Theme.accent)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Home / start screen

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var volumes: [Volume] = []

    var body: some View {
        VStack(spacing: 0) {
            // Pinned header so the back button stays put — without this the whole
            // screen is centered by ContentView's ZStack and the button is pushed
            // off the top when the window is short. Mirrors CleanupHeader.
            HStack {
                Button { model.showModePicker() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.panel))
                        .overlay(Circle().stroke(Theme.panelStroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Back")
                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.top, 22) // clear the macOS traffic-light buttons (hidden title bar)

            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 10) {
                        AppIcon(size: 88)
                        Text("UnDupe")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.primaryText)
                        Text("See what's eating your disk — and clear duplicates, safely.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.top, 24)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("CHOOSE WHAT TO SCAN")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryText)

                        targetRow(
                            icon: "house.fill",
                            title: "Home Folder",
                            subtitle: NSHomeDirectory(),
                            action: { model.startScan(path: model.homeVolume().path) }
                        )

                        ForEach(volumes) { volume in
                            targetRow(
                                icon: "externaldrive.fill",
                                title: volume.name,
                                subtitle: volume.totalBytes > 0
                                    ? "\(ByteFormat.string(volume.usedBytes)) used of \(ByteFormat.string(volume.totalBytes))"
                                    : volume.path,
                                action: { model.startScan(path: volume.path) }
                            )
                        }

                        targetRow(
                            icon: "folder.fill",
                            title: "Choose Folder…",
                            subtitle: "Pick any folder to scan",
                            action: chooseFolder
                        )
                    }
                    .frame(maxWidth: 540)

                    if let scanError = model.scanError {
                        scanErrorBanner(scanError)
                            .frame(maxWidth: 540)
                    }
                    if !model.hasFullDiskAccess {
                        fullDiskAccessHint
                            .frame(maxWidth: 540)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            volumes = model.availableVolumes()
            // The user may have granted access in System Settings since last time.
            model.refreshFullDiskAccess()
        }
    }

    private func targetRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(14)
            .glassPanel()
            .hoverHighlight(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }

    /// Shown when a scan failed outright, so a failure never looks like a
    /// cancellation (both land back on this screen).
    private func scanErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.primaryText)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.danger.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.danger.opacity(0.35), lineWidth: 1))
    }

    private var fullDiskAccessHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Theme.secondaryText)
            Text("To scan system folders and other drives, grant UnDupe Full Disk Access in System Settings ▸ Privacy & Security.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Button("Open Settings") { openPrivacySettings() }
                .font(.system(size: 11))
                .buttonStyle(.borderless)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.hairline))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url {
            model.startScan(path: url.path)
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Scan progress

struct ScanProgressView: View {
    @EnvironmentObject var model: AppModel
    @State private var startedAt = Date()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ScanRing()
                .frame(width: 116, height: 116)

            VStack(spacing: 4) {
                Text("Scanning \(scanTargetName)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.primaryText)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(elapsed(since: startedAt, now: context.date))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.tertiaryText)
                }
            }

            HStack(spacing: 28) {
                metric("\(model.scanFiles.formatted())", "files")
                metric(ByteFormat.string(model.scanBytes), "scanned")
            }

            Text(model.scanningPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
                .animation(.none, value: model.scanningPath)

            Button("Cancel") { model.cancelScan() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .padding(.top, 4)

            Spacer()
        }
        .padding(40)
    }

    private var scanTargetName: String {
        let name = (model.scanningPath as NSString).lastPathComponent
        return name.isEmpty ? "disk" : name
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.accent)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d elapsed", seconds / 60, seconds % 60)
    }
}

/// A continuously rotating dual-arc ring — a nod to the sunburst, signalling
/// active work without implying a known percentage.
private struct ScanRing: View {
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.hairline, lineWidth: 6)

            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))

            Circle()
                .trim(from: 0.5, to: 0.66)
                .stroke(Theme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                spin = true
            }
        }
    }
}
