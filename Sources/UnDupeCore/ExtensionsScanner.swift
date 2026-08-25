import Foundation

/// One installed extension/plugin. Two broad families:
/// - **App extensions** (Share, Action, Finder Sync, Widgets…) managed by
///   `pluginkit`. These are toggled on/off per-user — reversible, no file change.
/// - **Directory plugins** (QuickLook, Spotlight, Preference Panes, Internet
///   plug-ins, Screen Savers, Color Pickers) installed as bundles in known
///   folders. User-domain ones can be removed to the Trash. (Audio units are
///   intentionally excluded — they clutter the list without being meaningful junk.)
public struct SystemExtension: Identifiable, Hashable, Sendable {

    public enum Kind: String, Sendable, CaseIterable {
        case appExtension
        case quickLook
        case spotlight
        case preferencePane
        case internetPlugin
        case screenSaver
        case colorPicker

        public var label: String {
            switch self {
            case .appExtension:   return "App Extension"
            case .quickLook:      return "Quick Look"
            case .spotlight:      return "Spotlight Importer"
            case .preferencePane: return "Preference Pane"
            case .internetPlugin: return "Internet Plug-in"
            case .screenSaver:    return "Screen Saver"
            case .colorPicker:    return "Color Picker"
            }
        }

        /// App extensions are toggled via `pluginkit`; the rest are file bundles.
        public var isToggleable: Bool { self == .appExtension }
    }

    public enum State: String, Sendable {
        case enabled, disabled, unknown
    }

    public var id: String
    public let name: String
    public let kind: Kind
    public let path: String
    public let bundleId: String?
    public let owner: ItemOwner
    public let state: State
    public let sizeBytes: Int64

    /// App extensions can be enabled/disabled in-app unless they're Apple's
    /// (toggling is per-user and reversible, so non-Apple system ones qualify too).
    public var canToggle: Bool { kind.isToggleable && owner != .apple }

    /// Directory plugins can be moved to the Trash when they live in the user's
    /// home domain.
    public var canRemove: Bool { !kind.isToggleable && SystemItemClassifier.isActionable(owner) }
}

/// Discovers extensions/plugins and toggles or removes the actionable ones.
public enum ExtensionsScanner {

    /// Directory-plugin sources: kind → (folder, bundle extension).
    private static func directorySources() -> [(kind: SystemExtension.Kind, dir: String, ext: String)] {
        let home = NSHomeDirectory()
        let specs: [(SystemExtension.Kind, [String], String)] = [
            (.quickLook,      ["\(home)/Library/QuickLook", "/Library/QuickLook"], "qlgenerator"),
            (.spotlight,      ["\(home)/Library/Spotlight", "/Library/Spotlight"], "mdimporter"),
            (.preferencePane, ["\(home)/Library/PreferencePanes", "/Library/PreferencePanes"], "prefPane"),
            (.internetPlugin, ["\(home)/Library/Internet Plug-Ins", "/Library/Internet Plug-Ins"], "plugin"),
            (.screenSaver,    ["\(home)/Library/Screen Savers", "/Library/Screen Savers"], "saver"),
            (.colorPicker,    ["\(home)/Library/ColorPickers", "/Library/ColorPickers"], "colorPicker"),
        ]
        return specs.flatMap { kind, dirs, ext in dirs.map { (kind, $0, ext) } }
    }

    // MARK: - Scan

    /// Every discoverable extension, actionable items first, then by name.
    public static func scan() -> [SystemExtension] {
        var items = appExtensions()
        items.append(contentsOf: directoryPlugins())
        return items.sorted { lhs, rhs in
            let lhsAction = lhs.canToggle || lhs.canRemove
            let rhsAction = rhs.canToggle || rhs.canRemove
            if lhsAction != rhsAction { return lhsAction }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func appExtensions() -> [SystemExtension] {
        guard let output = runPluginkit(["-mAv"]) else { return [] }
        var items: [SystemExtension] = []

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let first = line.first, "+-?!".contains(first) else { continue }

            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.count >= 2 else { continue }

            let state: SystemExtension.State = first == "+" ? .enabled : (first == "-" ? .disabled : .unknown)
            let bundleId = String(tokens[1]).components(separatedBy: "(").first ?? String(tokens[1])
            guard let pathToken = tokens.last.map(String.init), pathToken.hasPrefix("/") else { continue }

            let owner = SystemItemClassifier.owner(path: pathToken, bundleIdentifier: bundleId)
            items.append(
                SystemExtension(
                    id: bundleId,
                    name: bundleId.components(separatedBy: ".").last ?? bundleId,
                    kind: .appExtension,
                    path: pathToken,
                    bundleId: bundleId,
                    owner: owner,
                    state: state,
                    sizeBytes: 0
                )
            )
        }
        return items
    }

    private static func directoryPlugins() -> [SystemExtension] {
        var items: [SystemExtension] = []
        for source in directorySources() {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: source.dir)) ?? []
            for entry in contents where (entry as NSString).pathExtension == source.ext {
                let path = "\(source.dir)/\(entry)"
                let bundleId = bundleIdentifier(at: path)
                let owner = SystemItemClassifier.owner(path: path, bundleIdentifier: bundleId)
                items.append(
                    SystemExtension(
                        id: path,
                        name: (entry as NSString).deletingPathExtension,
                        kind: source.kind,
                        path: path,
                        bundleId: bundleId,
                        owner: owner,
                        state: .enabled,
                        sizeBytes: directorySize(path)
                    )
                )
            }
        }
        return items
    }

    // MARK: - Actions

    /// Enables or disables an app extension via `pluginkit` (reversible, per-user).
    public static func setEnabled(_ ext: SystemExtension, enabled: Bool) {
        guard ext.canToggle, let id = ext.bundleId else { return }
        _ = runPluginkit(["-e", enabled ? "use" : "disable", "-i", id])
    }

    /// Moves a user-domain directory plugin to the Trash.
    public static func remove(_ ext: SystemExtension) -> TrashResult {
        guard ext.canRemove else {
            return TrashResult(
                path: ext.path,
                success: false,
                reclaimedBytes: 0,
                error: "Only your own plugins can be removed here."
            )
        }
        return SafeDelete.moveToTrash([.init(path: ext.path, size: ext.sizeBytes)]).first
            ?? TrashResult(path: ext.path, success: false, reclaimedBytes: 0, error: "Unknown error")
    }

    // MARK: - Helpers

    private static func bundleIdentifier(at path: String) -> String? {
        let plistPath = "\(path)/Contents/Info.plist"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    /// Summed allocated size of a bundle's files (plugin bundles are small).
    private static func directorySize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: keys)
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    @discardableResult
    private static func runPluginkit(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
