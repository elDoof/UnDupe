import AppKit
import SwiftUI
import UnDupeCore

/// Drives the update flow and the sheet that shows it.
///
/// Same threading contract as `AppModel`: work happens off the main queue and
/// every `@Published` mutation lands back on it.
@MainActor
final class UpdateModel: ObservableObject {

    /// Where releases are published.
    static let owner = "elDoof"
    static let repo = "UnDupe"

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(AppVersion)
        case available(Release)
        case installing
        case installed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var isSheetPresented = false

    /// A version the user chose to skip; they aren't nagged about it again.
    @AppStorage("skippedUpdateVersion") private var skippedVersion: String = ""
    /// Off switch for the silent check on launch. The manual menu item always works.
    @AppStorage("automaticUpdateChecks") var checksAutomatically: Bool = true

    private let service = UpdateService(owner: owner, repo: repo)

    var currentVersion: AppVersion? { AppVersion.current() }
    var releasesPageURL: URL { service.releasesPageURL }

    /// False for `swift run` and unsigned local builds, which can't verify or
    /// replace themselves. The menu item is hidden rather than left to fail.
    var isSupported: Bool { UpdateService.isSelfUpdateSupported() }

    // MARK: - Checking

    /// The silent check on launch. Only surfaces if there's something to say.
    func checkInBackground() async {
        guard checksAutomatically, isSupported, case .idle = phase else { return }
        await check(announcing: false)
    }

    /// The explicit "Check for Updates…" command, which always shows its result.
    func checkFromMenu() {
        isSheetPresented = true
        Task { await check(announcing: true) }
    }

    private func check(announcing: Bool) async {
        guard let current = currentVersion else {
            if announcing { phase = .failed(UpdateError.notInstalledAsApp.localizedDescription) }
            return
        }

        phase = .checking
        do {
            switch try await service.check(against: current) {
            case .upToDate(let version):
                phase = .upToDate(version)
            case .updateAvailable(let release):
                phase = .available(release)
                // A background check only interrupts for a version the user
                // hasn't already declined.
                if !announcing && release.tag != skippedVersion {
                    isSheetPresented = true
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
            // A failed background check is not worth a modal; the user didn't ask.
            if !announcing { isSheetPresented = false }
        }
    }

    // MARK: - Installing

    func install(_ release: Release) {
        phase = .installing
        Task {
            do {
                let installed = try await service.install(release)
                phase = .installed
                relaunch(at: installed)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func skip(_ release: Release) {
        skippedVersion = release.tag
        isSheetPresented = false
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(releasesPageURL)
    }

    // MARK: - Relaunch

    /// Quits and reopens the freshly installed copy.
    ///
    /// The helper waits for this process to actually exit before calling `open`:
    /// launching while the old instance is still alive would just re-activate
    /// the running app instead of starting the new one.
    private func relaunch(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; "
            + "/usr/bin/open \(shellQuoted(url.path))",
        ]
        do {
            try process.run()
        } catch {
            phase = .failed("Updated, but couldn't relaunch. Quit and reopen UnDupe.")
            return
        }
        NSApp.terminate(nil)
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
