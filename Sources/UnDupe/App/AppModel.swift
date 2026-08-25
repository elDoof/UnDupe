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

    /// Why the last scan produced nothing, when it wasn't a cancellation.
    /// Cleared whenever a new scan starts or the user returns home.
    @Published private(set) var scanError: String?

    /// Whether UnDupe can read protected locations. Without the grant a scan
    /// still succeeds but silently under-reports, so the UI has to say so.
    @Published private(set) var hasFullDiskAccess: Bool = FullDiskAccess.isGranted()

    private var scanEngine: ScanEngine?
    private var dupFinder: DuplicateFinder?

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
        phase = .home
        statusMessage = nil
        scanError = nil
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
        let succeededPaths = Set(results.filter { $0.success }.map { $0.path })
        let reclaimed = results.reduce(0) { $0 + $1.reclaimedBytes }
        let failures = results.filter { !$0.success }

        // Update the tree so the sunburst reflects freed space.
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

        if failures.isEmpty {
            statusMessage = "Moved \(succeededPaths.count) item(s) to Trash — freed \(ByteFormat.string(reclaimed))."
        } else {
            statusMessage = "Freed \(ByteFormat.string(reclaimed)). \(failures.count) item(s) couldn't be removed (protected or in use)."
        }
    }
}
