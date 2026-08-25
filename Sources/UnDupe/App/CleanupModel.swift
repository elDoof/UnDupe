import Foundation
import SwiftUI
import UnDupeCore

/// State and orchestration for the System Cleanup side of UnDupe. Kept separate
/// from `AppModel` (the disk-scan flow) so neither balloons. Follows the same
/// conventions: a plain `ObservableObject`, heavy work on a background queue, and
/// every `@Published` mutation hopped back to the main queue.
final class CleanupModel: ObservableObject {

    /// The cleanup modules surfaced on the cleanup home screen.
    enum Module: String, CaseIterable, Identifiable {
        case startup
        case extensions
        case junk
        case uninstaller

        var id: String { rawValue }

        var title: String {
            switch self {
            case .startup:     return "Startup & Background"
            case .extensions:  return "Extensions"
            case .junk:        return "System Junk"
            case .uninstaller: return "App Uninstaller"
            }
        }

        var subtitle: String {
            switch self {
            case .startup:     return "Login items and background services"
            case .extensions:  return "Browser, Finder, Spotlight & system plugins"
            case .junk:        return "Caches, logs & developer leftovers"
            case .uninstaller: return "Remove apps and their leftovers"
            }
        }

        var icon: String {
            switch self {
            case .startup:     return "bolt.badge.clock"
            case .extensions:  return "puzzlepiece.extension.fill"
            case .junk:        return "trash.slash.fill"
            case .uninstaller: return "xmark.bin.fill"
            }
        }
    }

    /// launchd-kind raw values, used to pick startup items out of the shared
    /// quarantine manifest (which can also hold extensions later).
    private static let startupKinds: Set<String> = [
        StartupItem.Kind.userAgent.rawValue,
        StartupItem.Kind.systemAgent.rawValue,
        StartupItem.Kind.daemon.rawValue,
    ]

    @Published var activeModule: Module?

    /// Drives the one-click "Automatic Cleanup" sheet presented over the dashboard.
    @Published var showAutoCleanup = false

    // MARK: Startup module state
    @Published private(set) var startupItems: [StartupItem] = []
    @Published private(set) var isScanningStartup = false
    @Published private(set) var disabledStartup: [QuarantineStore.Item] = []

    // MARK: Extensions module state
    @Published private(set) var extensions: [SystemExtension] = []
    @Published private(set) var isScanningExtensions = false

    // MARK: Junk module state
    @Published private(set) var junkCategories: [JunkCategory] = []
    @Published private(set) var isScanningJunk = false

    // MARK: Uninstaller module state
    @Published private(set) var installedApps: [InstalledApp] = []
    @Published private(set) var isScanningApps = false

    /// One-shot feedback after an action, shown then dismissed by the view.
    @Published var statusMessage: String?

    // MARK: - Navigation

    func open(_ module: Module) {
        activeModule = module
        switch module {
        case .startup:     loadStartupItems()
        case .extensions:  loadExtensions()
        case .junk:        loadJunk()
        case .uninstaller: loadApps()
        }
    }

    func closeModule() { activeModule = nil }

    /// Kicks off all four module scans for the dashboard. Each loader guards its
    /// own re-entrancy, so this is safe to call on every dashboard appearance.
    func loadDashboard() {
        loadStartupItems()
        loadExtensions()
        loadJunk()
        loadApps()
    }

    // MARK: - Dashboard stats

    /// Genuinely reclaimable space: removable junk plus the leftover cruft apps
    /// scatter (not the app bundles themselves — those are apps you may want).
    var reclaimableBytes: Int64 { junkBytes + appLeftoverBytes }

    var junkBytes: Int64 { junkCategories.reduce(0) { $0 + $1.totalBytes } }
    var appLeftoverBytes: Int64 { installedApps.reduce(0) { $0 + $1.leftoverBytes } }
    var uninstallableAppsBytes: Int64 {
        installedApps.filter { $0.canUninstall }.reduce(0) { $0 + $1.totalBytes }
    }

    /// Whether any module is still scanning — drives the dashboard's live state.
    var isScanningDashboard: Bool {
        isScanningStartup || isScanningExtensions || isScanningJunk || isScanningApps
    }

    /// Per-module scan state + headline figure for a dashboard row.
    func isScanning(_ module: Module) -> Bool {
        switch module {
        case .startup:     return isScanningStartup && startupItems.isEmpty
        case .extensions:  return isScanningExtensions && extensions.isEmpty
        case .junk:        return isScanningJunk && junkCategories.isEmpty
        case .uninstaller: return isScanningApps && installedApps.isEmpty
        }
    }

    /// Short headline for a module's dashboard row (e.g. "12.1 GB", "87 apps").
    func summary(for module: Module) -> String {
        switch module {
        case .startup:
            let mine = startupItems.filter { $0.isActionable }.count
            return "\(mine) yours · \(startupItems.count) total"
        case .extensions:
            let shown = extensions.filter { $0.owner != .apple }.count
            return "\(shown) extensions"
        case .junk:
            return ByteFormat.string(junkBytes)
        case .uninstaller:
            let count = installedApps.filter { $0.canUninstall }.count
            return "\(ByteFormat.string(uninstallableAppsBytes)) · \(count) apps"
        }
    }

    // MARK: - Startup: load

    func loadStartupItems() {
        guard !isScanningStartup else { return }
        isScanningStartup = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = StartupItemsScanner.scan()
            let disabled = QuarantineStore.list().filter { Self.startupKinds.contains($0.kind) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.startupItems = items
                self.disabledStartup = disabled.sorted { $0.disabledAt > $1.disabledAt }
                self.isScanningStartup = false
            }
        }
    }

    // MARK: - Startup: actions

    /// Reversibly disables the given user-domain agents, then refreshes the list.
    func disableStartup(_ items: [StartupItem]) {
        let actionable = items.filter { $0.isActionable }
        guard !actionable.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var disabled = 0
            var failures = 0
            for item in actionable {
                do { _ = try StartupItemsScanner.disable(item); disabled += 1 }
                catch { failures += 1 }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusMessage = failures == 0
                    ? "Disabled \(disabled) item(s). Re-enable any time below."
                    : "Disabled \(disabled). \(failures) couldn't be changed."
                self.loadStartupItems()
            }
        }
    }

    /// Permanently removes the given user-domain agents (to the Trash).
    func removeStartup(_ items: [StartupItem]) {
        let actionable = items.filter { $0.isActionable }
        guard !actionable.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = actionable.map { StartupItemsScanner.remove($0) }
            let succeeded = results.filter { $0.success }.count
            let failed = results.count - succeeded
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusMessage = failed == 0
                    ? "Moved \(succeeded) login item(s) to Trash."
                    : "Removed \(succeeded). \(failed) couldn't be removed."
                self.loadStartupItems()
            }
        }
    }

    /// Restores a previously disabled item and reloads it.
    func enableStartup(_ item: QuarantineStore.Item) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var message = "Re-enabled \(URL(fileURLWithPath: item.originalPath).lastPathComponent)."
            do { try StartupItemsScanner.enable(item) }
            catch { message = "Couldn't re-enable: \(error.localizedDescription)" }
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusMessage = message
                self.loadStartupItems()
            }
        }
    }

    // MARK: - Extensions: load

    func loadExtensions() {
        guard !isScanningExtensions else { return }
        isScanningExtensions = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = ExtensionsScanner.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.extensions = items
                self.isScanningExtensions = false
            }
        }
    }

    // MARK: - Extensions: actions

    /// Toggles an app extension on/off (reversible, via pluginkit), then refreshes.
    func toggleExtension(_ ext: SystemExtension, enabled: Bool) {
        guard ext.canToggle else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            ExtensionsScanner.setEnabled(ext, enabled: enabled)
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusMessage = "\(enabled ? "Enabled" : "Disabled") \(ext.name)."
                self.loadExtensions()
            }
        }
    }

    /// Moves the given user-domain plugins to the Trash, then refreshes.
    func removeExtensions(_ items: [SystemExtension]) {
        let removable = items.filter { $0.canRemove }
        guard !removable.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = removable.map { ExtensionsScanner.remove($0) }
            let succeeded = results.filter { $0.success }.count
            let failed = results.count - succeeded
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusMessage = failed == 0
                    ? "Moved \(succeeded) plugin(s) to Trash."
                    : "Removed \(succeeded). \(failed) couldn't be removed."
                self.loadExtensions()
            }
        }
    }

    // MARK: - Junk: load

    func loadJunk() {
        guard !isScanningJunk else { return }
        isScanningJunk = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let categories = JunkScanner.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.junkCategories = categories
                self.isScanningJunk = false
            }
        }
    }

    // MARK: - Junk: actions

    /// Moves the given junk items to the Trash, then rescans.
    func removeJunk(_ items: [JunkItem]) {
        autoCleanJunk(items) { _, _ in }
    }

    /// Core junk-removal path: removes the items, updates `statusMessage`, rescans,
    /// then reports `(reclaimedBytes, failedCount)` back so a caller (the Automatic
    /// Cleanup sheet) can show its own result. Defaults to the Trash (reversible);
    /// `permanently: true` skips the Trash — opt-in, the caller must confirm first.
    func autoCleanJunk(_ items: [JunkItem], permanently: Bool = false, completion: @escaping (Int64, Int) -> Void) {
        guard !items.isEmpty else { completion(0, 0); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = JunkScanner.remove(items, permanently: permanently)
            let succeeded = results.filter { $0.success }.count
            let reclaimed = results.reduce(0) { $0 + $1.reclaimedBytes }
            let failed = results.count - succeeded
            let verb = permanently ? "Deleted" : "Cleared"
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusMessage = failed == 0
                    ? "\(verb) \(succeeded) item(s) — freed \(ByteFormat.string(reclaimed))."
                    : "\(verb) \(succeeded) (\(ByteFormat.string(reclaimed))). \(failed) couldn't be removed."
                self.loadJunk()
                completion(reclaimed, failed)
            }
        }
    }

    // MARK: - Uninstaller: load

    func loadApps() {
        guard !isScanningApps else { return }
        isScanningApps = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = AppUninstaller.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.installedApps = apps
                self.isScanningApps = false
            }
        }
    }

    // MARK: - Uninstaller: actions

    /// Uninstalls the given apps to the Trash, then rescans. Each app's bundle is
    /// always removed; for its leftovers, any path in `keptLeftovers` is left in
    /// place (the user chose to keep it — e.g. preferences), everything else goes.
    func uninstallApps(_ apps: [InstalledApp], keepingLeftovers keptLeftovers: Set<String> = []) {
        let removable = apps.filter { $0.canUninstall }
        guard !removable.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = removable.flatMap { app -> [TrashResult] in
                let leftoverPaths = Set(app.leftovers.map(\.path)).subtracting(keptLeftovers)
                return AppUninstaller.uninstall(app, includingLeftovers: leftoverPaths)
            }
            let succeeded = results.filter { $0.success }.count
            let failed = results.count - succeeded
            let reclaimed = results.reduce(0) { $0 + $1.reclaimedBytes }
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusMessage = failed == 0
                    ? "Uninstalled \(removable.count) app(s) — freed \(ByteFormat.string(reclaimed))."
                    : "Uninstalled \(removable.count) app(s), \(ByteFormat.string(reclaimed)) freed. \(failed) item(s) couldn't be removed."
                self.loadApps()
            }
        }
    }
}
