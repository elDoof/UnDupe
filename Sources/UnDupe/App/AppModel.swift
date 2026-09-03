import Foundation
import SwiftUI
import UnDupeCore

/// A mounted volume the user can choose to scan.
struct Volume: Identifiable, Hashable {
    let id: String          // path, stable
    let name: String
    let path: String
    let totalBytes: Int64
    let availableBytes: Int64
    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
}

/// Central app state and orchestration. Plain `ObservableObject` (not an actor):
/// heavy work runs on background queues and all `@Published` mutations are hopped
/// back to the main queue explicitly.
final class AppModel: ObservableObject {

    enum Phase: Equatable {
        case home
        case scanning
        case results
    }

    /// The top-level area of the app. The mode picker is the entry point; from
    /// there the user drops into the disk-scan flow (`.disk`, driven by `phase`)
    /// or the System Cleanup area (`.cleanup`, driven by `CleanupModel`).
    enum TopLevel: Equatable {
        case picker
        case disk
        case cleanup
    }

    @Published var topLevel: TopLevel = .picker
    @Published var phase: Phase = .home

    /// Every scanned tree this session (multiple = cross-drive comparison).
    @Published private(set) var roots: [FileNode] = []
    /// The tree currently shown in the sunburst.
    @Published var selectedRoot: FileNode?

    // Scan progress
    @Published private(set) var scanFiles: Int = 0
    @Published private(set) var scanBytes: Int64 = 0
    @Published private(set) var scanningPath: String = ""

    // Duplicates
    @Published private(set) var duplicates: [DuplicateGroup] = []
    @Published private(set) var isFindingDuplicates = false
    @Published private(set) var dupHashed: Int = 0
    @Published private(set) var dupTotal: Int = 0

    // One-shot feedback after a trash action.
    @Published var statusMessage: String?

    /// Whether the last trash can still be put back. Drives the Undo affordance
    /// on the status toast and the Edit ▸ Undo menu item.
    @Published private(set) var canUndoTrash = false

    /// Why the last scan produced nothing, when it wasn't a cancellation.
    /// Cleared whenever a new scan starts or the user returns home.
    @Published private(set) var scanError: String?

    /// Whether UnDupe can read protected locations. Without the grant a scan
    /// still succeeds but silently under-reports, so the UI has to say so.
    @Published private(set) var hasFullDiskAccess: Bool = FullDiskAccess.isGranted()

    private var scanEngine: ScanEngine?
    private var dupFinder: DuplicateFinder?

    /// Everything needed to reverse the most recent trash. Single level by
    /// design: a second trash replaces it rather than building a stack, which
    /// keeps the promise the UI makes ("Undo") honest and unambiguous.
    private struct TrashUndo {
        /// Only the items that actually reached the Trash — a refused item has
        /// nothing to put back.
        let results: [TrashResult]
        /// Nodes to splice back into the tree, paired with the parent they hung
        /// from. `detachFromParent()` nils that link, so it is captured first.
        let detached: [(node: FileNode, parent: FileNode)]
        /// The duplicate groups as they stood before trashing pruned them.
        let duplicates: [DuplicateGroup]
    }

    private var lastTrash: TrashUndo? {
        didSet { canUndoTrash = lastTrash != nil }
    }

    var totalReclaimable: Int64 { duplicates.reduce(0) { $0 + $1.reclaimableBytes } }

    // MARK: - Volumes

    func availableVolumes() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        var volumes: [Volume] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true else { continue }
            volumes.append(
                Volume(
                    id: url.path,
                    name: values.volumeName ?? url.lastPathComponent,
                    path: url.path,
                    totalBytes: Int64(values.volumeTotalCapacity ?? 0),
                    availableBytes: Int64(values.volumeAvailableCapacity ?? 0)
                )
            )
        }
        return volumes
    }

    /// The user's home folder — usually the most useful first scan.
    func homeVolume() -> Volume {
        let home = NSHomeDirectory()
        return Volume(id: home, name: "Home", path: home, totalBytes: 0, availableBytes: 0)
    }

    // MARK: - Scanning

    func startScan(path: String) {
        let engine = ScanEngine()
        scanEngine = engine

        scanFiles = 0
        scanBytes = 0
        scanningPath = path
        scanError = nil
        duplicates = []
        // The pending undo refers to nodes in the tree we're about to discard;
        // reattaching them afterwards would splice orphans into nothing.
        lastTrash = nil
        phase = .scanning

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = engine.scan(rootPath: path) { progress in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.scanFiles = progress.filesScanned
                    self.scanBytes = progress.bytesScanned
                    self.scanningPath = progress.currentPath
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .cancelled:
                    self.phase = .home
                case .failed(let failure):
                    // Never bounce home silently: a failed scan and a cancelled
                    // one look identical from the home screen otherwise.
                    self.scanError = failure.message
                    self.hasFullDiskAccess = FullDiskAccess.isGranted()
                    self.phase = .home
                case .completed(let root):
                    // Replace, don't append: a rescan should drop the previous tree
                    // so repeat scans don't stack whole trees in RAM. An explicit
                    // "compare another drive" action would append on its own path.
                    self.roots = [root]
                    self.selectedRoot = root
                    self.phase = .results
                }
            }
        }
    }

    func cancelScan() {
        scanEngine?.cancel()
    }

    // MARK: - Top-level navigation

    /// Enters the disk-scan flow at its start screen (the target chooser).
    func enterDiskMode() {
        topLevel = .disk
        phase = .home
    }

    /// Enters the System Cleanup area.
    func enterCleanupMode() {
        topLevel = .cleanup
    }

    /// Returns to the mode picker (the app's entry point).
    func showModePicker() {
        topLevel = .picker
    }

    /// Discards all results and returns to the start screen.
    func reset() {
        scanEngine?.cancel()
        dupFinder?.cancel()
        roots = []
        selectedRoot = nil
        duplicates = []
        lastTrash = nil
        phase = .home
        statusMessage = nil
        scanError = nil
    }

    /// Re-runs the scan on the folder currently being shown. The map is a
    /// snapshot, so this is how the user picks up changes made outside UnDupe.
    func rescan() {
        guard let root = selectedRoot else { return }
        startScan(path: root.path)
    }

    /// Re-probes the Full Disk Access grant. Cheap, and worth doing whenever the
    /// home screen appears: the user may have just granted it in System Settings.
    func refreshFullDiskAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted()
    }

    // MARK: - Duplicates

    func findDuplicates() {
        guard !roots.isEmpty, !isFindingDuplicates else { return }
        let finder = DuplicateFinder()
        dupFinder = finder
        let rootsSnapshot = roots

        isFindingDuplicates = true
        dupHashed = 0
        dupTotal = 0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let groups = finder.find(in: rootsSnapshot) { progress in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.dupHashed = progress.filesHashed
                    self.dupTotal = progress.totalToHash
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.duplicates = groups
                self.isFindingDuplicates = false
            }
        }
    }

    // MARK: - Trashing

    /// Moves the given files to the Trash and updates the map + duplicate list.
    func trash(_ files: [FileNode]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = SafeDelete.moveToTrash(files)
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyTrashResults(results, files: files)
            }
        }
    }

    private func applyTrashResults(_ results: [TrashResult], files: [FileNode]) {
        let succeeded = results.filter { $0.success }
        let succeededPaths = Set(succeeded.map { $0.path })
        let reclaimed = results.reduce(0) { $0 + $1.reclaimedBytes }
        let failures = results.filter { !$0.success }

        // Captured before the detach loop below: `detachFromParent()` nils the
        // parent link an undo would need to put the node back.
        let detached = files.compactMap { file -> (node: FileNode, parent: FileNode)? in
            guard succeededPaths.contains(file.path), let parent = file.parent else { return nil }
            return (file, parent)
        }
        let duplicatesBeforeTrash = duplicates

        // Update the tree so the map reflects freed space.
        for file in files where succeededPaths.contains(file.path) {
            file.detachFromParent()
        }

        // Drop trashed files from duplicate groups; remove groups that fall below 2.
        duplicates = duplicates.compactMap { group in
            let remaining = group.files.filter { !succeededPaths.contains($0.path) }
            guard remaining.count > 1 else { return nil }
            return DuplicateGroup(sizeBytes: group.sizeBytes, files: remaining)
        }

        objectWillChange.send()   // FileNode mutations aren't observable on their own

        lastTrash = succeeded.isEmpty
            ? nil
            : TrashUndo(results: succeeded, detached: detached, duplicates: duplicatesBeforeTrash)

        if failures.isEmpty {
            statusMessage = "Moved \(succeededPaths.count) item(s) to Trash — freed \(ByteFormat.string(reclaimed))."
        } else {
            statusMessage = "Freed \(ByteFormat.string(reclaimed)). \(failures.count) item(s) couldn't be removed (protected or in use)."
        }
    }

    // MARK: - Undo

    /// Puts the most recent trash back: the files return to disk and the tree
    /// returns to the totals it showed beforehand.
    func undoLastTrash() {
        guard let undo = lastTrash else { return }
        // Taken immediately so a double-click on Undo can't run the restore twice.
        lastTrash = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let restored = SafeDelete.putBack(undo.results)
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyUndoResults(restored, undo: undo)
            }
        }
    }

    private func applyUndoResults(_ restored: [TrashResult], undo: TrashUndo) {
        let restoredPaths = Set(restored.filter { $0.success }.map { $0.path })
        let putBack = restored.reduce(0) { $0 + $1.reclaimedBytes }
        let failures = restored.filter { !$0.success }

        for entry in undo.detached where restoredPaths.contains(entry.node.path) {
            entry.node.reattach(to: entry.parent)
        }

        // Only restore the duplicate list when every copy came back. A partial
        // restore would leave groups pointing at files still sitting in the Trash.
        if failures.isEmpty {
            duplicates = undo.duplicates
        }

        objectWillChange.send()

        if failures.isEmpty {
            statusMessage = "Put \(restoredPaths.count) item(s) back — \(ByteFormat.string(putBack)) restored."
        } else if restoredPaths.isEmpty {
            statusMessage = failures.first?.error
                ?? "Nothing could be put back — the Trash may have been emptied."
        } else {
            statusMessage = "Put \(restoredPaths.count) item(s) back. \(failures.count) couldn't be restored."
        }
    }
}
