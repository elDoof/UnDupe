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
    /// Built into the Mac rather than plugged in — only affects the icon.
    var isInternal = false
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
    /// The folder being read right now. Changes many times a second.
    @Published private(set) var scanningPath: String = ""
    /// The folder the user asked to scan. Stable for the whole scan, which is
    /// what a headline needs.
    @Published private(set) var scanRootPath: String = ""

    /// Folders the finished scan could not read. Non-zero means the totals on
    /// screen are a lower bound, and the UI says so.
    @Published private(set) var skippedDirectoryCount = 0

    // Duplicates
    @Published private(set) var duplicates: [DuplicateGroup] = []
    @Published private(set) var isFindingDuplicates = false
    /// Whether a duplicate search has finished for the current scan. Without it
    /// "no duplicates" and "haven't looked yet" are both an empty list, and the
    /// search silently re-ran every time the tab was opened.
    @Published private(set) var hasSearchedDuplicates = false
    @Published private(set) var dupHashed: Int = 0
    @Published private(set) var dupTotal: Int = 0
    /// Ids of the duplicate copies marked for the Trash. Held here rather than
    /// in the view so it survives switching between the map and the list.
    @Published private(set) var markedDuplicateIDs: Set<UUID> = []

    /// Includes descendants so cached map shapes cannot act on removed items.
    @Published private(set) var trashedNodeIDs: Set<UUID> = []

    // One-shot feedback after a trash action.
    @Published var statusMessage: String?
    /// True when `statusMessage` reports something that didn't fully work, so
    /// the toast doesn't dress a failure in success green.
    @Published private(set) var statusIsWarning = false

    /// Whether the last trash can still be put back. Drives the Undo affordance
    /// on the status toast and the Edit ▸ Undo menu item.
    @Published private(set) var canUndoTrash = false

    /// Why the last scan produced nothing, when it wasn't a cancellation.
    /// Cleared whenever a new scan starts or the user returns home.
    @Published private(set) var scanError: String?

    /// Whether UnDupe can read protected locations. Without the grant a scan
    /// still succeeds but silently under-reports, so the UI has to say so.
    @Published private(set) var hasFullDiskAccess: Bool = FullDiskAccess.isGranted()

    /// The folder the map is zoomed into, kept up to date by the results screen
    /// so a rescan (including one from the menu bar) can come back to it.
    var focusedPath: String?

    /// The scan in flight, or the one whose results are on screen. Completions
    /// and progress from any *other* engine are stale and are dropped — see
    /// `startScan`.
    private var scanEngine: ScanEngine?
    private var dupFinder: DuplicateFinder?
    /// Where the next results screen should zoom to, set by a rescan.
    private var focusPathToRestore: String?

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

    /// True only while a finished scan is on screen. Rescan and Undo are
    /// meaningless anywhere else, and Rescan during a scan would start a second.
    var isShowingResults: Bool {
        topLevel == .disk && phase == .results && selectedRoot != nil
    }

    // MARK: - Volumes

    func availableVolumes() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeIsBrowsableKey,
            .volumeIsInternalKey,
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
                    availableBytes: Int64(values.volumeAvailableCapacity ?? 0),
                    isInternal: values.volumeIsInternal ?? false
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

    /// Starts scanning `path`, replacing whatever was scanned before.
    ///
    /// - Parameter restoringFocus: a folder to zoom back into once the results
    ///   appear, used by `rescan` so a refresh doesn't lose the user's place.
    func startScan(path: String, restoringFocus: String? = nil) {
        // Anything still running belongs to the tree we're about to discard.
        scanEngine?.cancel()
        cancelDuplicateSearch()

        let engine = ScanEngine()
        scanEngine = engine

        scanFiles = 0
        scanBytes = 0
        scanningPath = path
        scanRootPath = path
        scanError = nil
        skippedDirectoryCount = 0
        duplicates = []
        hasSearchedDuplicates = false
        markedDuplicateIDs = []
        focusPathToRestore = restoringFocus
        focusedPath = nil
        // The pending undo refers to nodes in the tree we're about to discard;
        // reattaching them afterwards would splice orphans into nothing.
        lastTrash = nil
        trashedNodeIDs = []
        statusMessage = nil
        phase = .scanning

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = engine.scan(rootPath: path) { progress in
                DispatchQueue.main.async {
                    // A superseded scan keeps reporting until it unwinds; its
                    // numbers must not overwrite the current scan's.
                    guard let self, self.scanEngine === engine else { return }
                    self.scanFiles = progress.filesScanned
                    self.scanBytes = progress.bytesScanned
                    self.scanningPath = progress.currentPath
                }
            }
            let skipped = engine.skippedDirectoryCount
            DispatchQueue.main.async {
                // Cancelling scan A and starting B means A still finishes, late,
                // as `.cancelled`. Acting on it would throw the user back to the
                // home screen in the middle of B.
                guard let self, self.scanEngine === engine else { return }
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
                    self.skippedDirectoryCount = skipped
                    self.hasFullDiskAccess = FullDiskAccess.isGranted()
                    self.phase = .results
                }
            }
        }
    }

    func cancelScan() {
        scanEngine?.cancel()
    }

    /// The folder the results screen should open zoomed into, if a rescan asked
    /// for one. Returned once, then forgotten.
    func takeFocusPathToRestore() -> String? {
        defer { focusPathToRestore = nil }
        return focusPathToRestore
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

    /// File ▸ New Scan: discards any results and shows the target chooser,
    /// wherever in the app the user currently is.
    func startNewScan() {
        reset()
        topLevel = .disk
    }

    /// Discards all results and returns to the start screen.
    func reset() {
        scanEngine?.cancel()
        // Dropping the reference is what makes the cancelled scan's late
        // completion a no-op rather than a second trip home.
        scanEngine = nil
        cancelDuplicateSearch()
        roots = []
        selectedRoot = nil
        duplicates = []
        hasSearchedDuplicates = false
        markedDuplicateIDs = []
        skippedDirectoryCount = 0
        focusPathToRestore = nil
        focusedPath = nil
        lastTrash = nil
        trashedNodeIDs = []
        phase = .home
        statusMessage = nil
        scanError = nil
    }

    /// Re-runs the scan on the folder currently being shown. The map is a
    /// snapshot, so this is how the user picks up changes made outside UnDupe.
    func rescan() {
        guard isShowingResults, let root = selectedRoot else { return }
        startScan(path: root.path, restoringFocus: focusedPath)
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
                    guard let self, self.dupFinder === finder else { return }
                    self.dupHashed = progress.filesHashed
                    self.dupTotal = progress.totalToHash
                }
            }
            DispatchQueue.main.async {
                // A search that was cancelled, or that belongs to a tree since
                // replaced by a rescan, must not install its groups: they would
                // point at nodes the map no longer shows.
                guard let self, self.dupFinder === finder else { return }
                self.dupFinder = nil
                self.duplicates = groups
                self.markedDuplicateIDs = DuplicateSelection.defaultMarks(for: groups)
                self.isFindingDuplicates = false
                self.hasSearchedDuplicates = true
            }
        }
    }

    /// Stops a duplicate search in progress. The list is left as "not searched"
    /// rather than "no duplicates", so the screen offers to start again.
    func cancelDuplicateSearch() {
        dupFinder?.cancel()
        dupFinder = nil
        isFindingDuplicates = false
    }

    /// Flips one copy between "keep" and "trash". Marking the last kept copy of
    /// a set is refused by `DuplicateSelection`.
    func toggleDuplicateMark(_ file: FileNode, in group: DuplicateGroup) {
        markedDuplicateIDs = DuplicateSelection.toggling(file, in: group, marked: markedDuplicateIDs)
    }

    /// Back to the default: keep one copy of each set, mark the rest.
    func resetDuplicateSelection() {
        markedDuplicateIDs = DuplicateSelection.defaultMarks(for: duplicates)
    }

    // MARK: - Trashing

    /// Moves the given files to the Trash and updates the map + duplicate list.
    func trash(_ files: [FileNode]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = SafeDelete.moveToTrash(files)
            DispatchQueue.main.async {
                self?.applyTrashResults(results, files: files)
            }
        }
    }

    /// Trashes every marked duplicate, set by set.
    ///
    /// The list is a snapshot from when the search ran, so each set is checked
    /// against the disk first: if the copy it was going to keep is gone, the
    /// set is left alone rather than losing its last copy.
    func trashMarkedDuplicates() {
        let groups = duplicates
        let marked = markedDuplicateIDs
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plan = DuplicateSelection.trashPlan(for: groups, marked: marked) {
                FileManager.default.fileExists(atPath: $0)
            }
            let results = SafeDelete.moveToTrash(plan.files)
            DispatchQueue.main.async {
                self?.applyTrashResults(results, files: plan.files,
                                        skippedSetCount: plan.skippedGroupCount)
            }
        }
    }

    /// Trashes a single duplicate (the right-click path), under the same rule
    /// as the batch: another copy must still exist on disk.
    func trashDuplicate(_ file: FileNode, in group: DuplicateGroup) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hasOtherCopy = DuplicateSelection.hasOtherCopyOnDisk(than: file, in: group) {
                FileManager.default.fileExists(atPath: $0)
            }
            guard hasOtherCopy else {
                DispatchQueue.main.async {
                    self?.showStatus(
                        "Kept “\(file.name)” — the other copies in its set are no longer on disk.",
                        isWarning: true
                    )
                }
                return
            }
            let results = SafeDelete.moveToTrash([file])
            DispatchQueue.main.async {
                self?.applyTrashResults(results, files: [file])
            }
        }
    }

    private func showStatus(_ message: String, isWarning: Bool = false) {
        statusIsWarning = isWarning
        statusMessage = message
    }

    private func applyTrashResults(_ results: [TrashResult], files: [FileNode], skippedSetCount: Int = 0) {
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
            markTrashed(file, removed: true)
            file.detachFromParent()
        }

        // Drop trashed files from duplicate groups; remove groups that fall below 2.
        duplicates = duplicates.compactMap { group in
            let remaining = group.files.filter { !succeededPaths.contains($0.path) }
            guard remaining.count > 1 else { return nil }
            return DuplicateGroup(sizeBytes: group.sizeBytes, files: remaining)
        }

        objectWillChange.send()   // FileNode mutations aren't observable on their own

        // Undo always refers to the action the toast is describing. A trash
        // that moved nothing therefore clears it: offering "Undo" beside
        // "Nothing was moved" would quietly reverse some earlier trash instead.
        lastTrash = succeeded.isEmpty
            ? nil
            : TrashUndo(results: succeeded, detached: detached, duplicates: duplicatesBeforeTrash)

        showStatus(
            Self.trashSummary(moved: succeeded.count, reclaimed: reclaimed,
                              failed: failures.count, skippedSets: skippedSetCount),
            isWarning: !failures.isEmpty || skippedSetCount > 0
        )
    }

    /// The one-line result of a trash, covering what moved, what was refused,
    /// and any duplicate sets left alone because their kept copy had vanished.
    static func trashSummary(moved: Int, reclaimed: Int64, failed: Int, skippedSets: Int) -> String {
        var parts: [String] = []
        if moved > 0 {
            parts.append("Moved \(CountFormat.string(moved, "item")) to Trash — freed \(ByteFormat.string(reclaimed)).")
        } else {
            parts.append("Nothing was moved to the Trash.")
        }
        if failed > 0 {
            parts.append("\(CountFormat.string(failed, "item")) couldn't be removed (protected or in use).")
        }
        if skippedSets > 0 {
            parts.append("Left \(CountFormat.string(skippedSets, "set")) alone: the copy to keep is no longer on disk.")
        }
        return parts.joined(separator: " ")
    }

    private func markTrashed(_ node: FileNode, removed: Bool) {
        if removed { trashedNodeIDs.insert(node.id) }
        else { trashedNodeIDs.remove(node.id) }
        for child in node.children { markTrashed(child, removed: removed) }
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
            markTrashed(entry.node, removed: false)
        }

        // Only restore the duplicate list when every copy came back. A partial
        // restore would leave groups pointing at files still sitting in the Trash.
        if failures.isEmpty {
            duplicates = undo.duplicates
        }

        objectWillChange.send()

        let restoredCount = CountFormat.string(restoredPaths.count, "item")
        if failures.isEmpty {
            showStatus("Put \(restoredCount) back — \(ByteFormat.string(putBack)) restored.")
        } else if restoredPaths.isEmpty {
            showStatus(
                failures.first?.error ?? "Nothing could be put back — the Trash may have been emptied.",
                isWarning: true
            )
        } else {
            showStatus(
                "Put \(restoredCount) back. \(CountFormat.string(failures.count, "item")) couldn't be restored.",
                isWarning: true
            )
        }
    }
}
