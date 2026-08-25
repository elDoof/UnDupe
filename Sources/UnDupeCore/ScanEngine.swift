import Foundation

/// Orchestrates a fast, parallel scan of a directory tree and builds a `FileNode`
/// hierarchy with accumulated sizes.
///
/// Top-level subdirectories are walked concurrently (one work item each, via
/// `concurrentPerform`); within a subtree the walk is a tight synchronous
/// recursion over `FastDirectoryScanner.read`. Progress is reported (throttled)
/// from worker threads — callers must hop to the main thread themselves.
/// Why a scan produced no tree. Distinguishing these matters: an unreadable
/// root looks exactly like an empty one to the directory reader.
public enum ScanFailure: Equatable {
    case pathNotFound
    case notADirectory
    case unreadable

    /// User-facing explanation, phrased as what to do about it.
    public var message: String {
        switch self {
        case .pathNotFound:
            return "That location no longer exists. It may have been moved, renamed, or ejected."
        case .notADirectory:
            return "That's a file, not a folder. Pick a folder or a volume to scan."
        case .unreadable:
            return "UnDupe isn't allowed to read that location. Grant Full Disk Access in System Settings ▸ Privacy & Security, then try again."
        }
    }
}

/// The result of a scan. Modelled as three cases rather than an optional tree
/// so callers cannot accidentally treat a failure as a cancellation.
public enum ScanOutcome {
    case completed(FileNode)
    case cancelled
    case failed(ScanFailure)

    /// The tree, when the scan actually finished.
    public var tree: FileNode? {
        if case .completed(let root) = self { return root }
        return nil
    }
}

public final class ScanEngine {

    /// A throttled snapshot of scan progress.
    public struct Progress {
        public let filesScanned: Int
        public let bytesScanned: Int64
        public let currentPath: String
    }

    /// Minimum interval between progress callbacks, to avoid flooding the UI.
    private static let progressThrottle: TimeInterval = 0.03

    private let lock = NSLock()
    private var cancelledFlag = false
    private var filesScanned = 0
    private var bytesScanned: Int64 = 0
    private var lastProgressReport = Date.distantPast
    private var progressHandler: ((Progress) -> Void)?

    /// Nested mount points to treat as opaque, so the scan stays on the volume the
    /// user chose instead of descending into other mounted drives. Computed once
    /// per scan in `scanSync`; only read by worker threads afterward.
    private var foreignMounts: Set<String> = []

    /// Device id of the scan root's volume. The scan stays on one volume (foreign
    /// mounts are opaque) and hard links can't cross volumes, so stamping every
    /// file node with this one value is exact. Set once in `scanSync`, then only
    /// read by worker threads. 0 if the root couldn't be stat'd.
    private var rootDeviceID: UInt64 = 0

    public init() {}

    /// Requests cancellation. Workers stop at the next directory boundary and the
    /// partial tree is discarded by `scanSync`.
    public func cancel() {
        lock.lock(); cancelledFlag = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelledFlag
    }

    /// Scans `rootPath` synchronously. Intended to be called on a background queue.
    ///
    /// Scans `rootPath` on the calling thread.
    ///
    /// Returns an outcome rather than an optional tree because "nothing came
    /// back" has three very different meanings to a user: they cancelled, the
    /// path is wrong, or the path is there but unreadable. The last one is the
    /// dangerous case — `FastDirectoryScanner.read` returns an empty array when
    /// `open(2)` is denied, so without the pre-flight check below an
    /// unreadable root would render as a perfectly valid, entirely empty disk.
    public func scan(rootPath: String, progress: @escaping (Progress) -> Void) -> ScanOutcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory) else {
            return .failed(.pathNotFound)
        }
        guard isDirectory.boolValue else { return .failed(.notADirectory) }
        // Usually a missing Full Disk Access grant rather than mode bits.
        guard access(rootPath, R_OK) == 0 else { return .failed(.unreadable) }

        lock.lock()
        cancelledFlag = false
        filesScanned = 0
        bytesScanned = 0
        lastProgressReport = .distantPast
        lock.unlock()
        progressHandler = progress
        foreignMounts = VolumeBoundary.foreignMountPoints(under: rootPath)
        rootDeviceID = Self.deviceID(of: rootPath)

        let rootName = (rootPath as NSString).lastPathComponent
        let root = FileNode(
            name: rootName.isEmpty ? rootPath : rootName,
            path: rootPath,
            isDirectory: true,
            size: 0
        )

        let entries = FastDirectoryScanner.read(path: rootPath)
        var topFiles: [DirEntry] = []
        var topDirs: [DirEntry] = []
        var opaqueDirs: [DirEntry] = []
        for entry in entries where entry.name != "." && entry.name != ".." && !entry.isSymlink {
            if entry.isDirectory {
                if ScanExclusions.shouldTreatAsOpaque(path: join(rootPath, entry.name), entry: entry, foreignMounts: foreignMounts) {
                    opaqueDirs.append(entry)
                } else {
                    topDirs.append(entry)
                }
            } else if entry.isRegularFile {
                topFiles.append(entry)
            }
            // Special files (FIFOs, sockets, devices) are skipped entirely.
        }

        var children: [FileNode] = []
        var total: Int64 = 0
        var count = 0

        // Top-level files first (cheap, single-threaded).
        for entry in topFiles {
            let node = FileNode(
                name: entry.name,
                path: join(rootPath, entry.name),
                isDirectory: false,
                size: entry.allocatedSize,
                inode: entry.fileID,
                deviceID: rootDeviceID
            )
            node.parent = root
            children.append(node)
            total += entry.allocatedSize
            count += 1
        }
        reportProgress(addFiles: topFiles.count,
                       addBytes: topFiles.reduce(0) { $0 + $1.allocatedSize },
                       path: rootPath)

        // Top-level subdirectories in parallel.
        let resultsLock = NSLock()
        var dirNodes: [FileNode] = []
        DispatchQueue.concurrentPerform(iterations: topDirs.count) { index in
            if self.isCancelled { return }
            let entry = topDirs[index]
            let node = self.buildSubtree(path: self.join(rootPath, entry.name), name: entry.name)
            resultsLock.lock(); dirNodes.append(node); resultsLock.unlock()
        }

        if isCancelled { return .cancelled }

        for node in dirNodes {
            node.parent = root
            total += node.size
            count += node.fileCount
        }
        children.append(contentsOf: dirNodes)

        // Cloud/file-provider directories: shown as zero-size leaves, never crawled.
        for entry in opaqueDirs {
            let node = FileNode(name: entry.name, path: join(rootPath, entry.name), isDirectory: true, size: 0)
            node.parent = root
            children.append(node)
        }

        root.children = children
        root.size = total
        root.fileCount = count
        root.sortDescendingBySize()
        return .completed(root)
    }

    // MARK: - Recursive subtree walk (single-threaded per subtree)

    private func buildSubtree(path: String, name: String) -> FileNode {
        let node = FileNode(name: name, path: path, isDirectory: true, size: 0)
        if isCancelled { return node }

        let entries = FastDirectoryScanner.read(path: path)
        var children: [FileNode] = []
        var total: Int64 = 0
        var count = 0
        var directFileCount = 0
        var directFileBytes: Int64 = 0

        for entry in entries where entry.name != "." && entry.name != ".." && !entry.isSymlink {
            let childPath = join(path, entry.name)
            if entry.isDirectory {
                // Cloud/file-provider directories are represented but not crawled:
                // descending is slow (provider-mediated) and can trigger downloads.
                let child: FileNode
                if ScanExclusions.shouldTreatAsOpaque(path: childPath, entry: entry, foreignMounts: foreignMounts) {
                    child = FileNode(name: entry.name, path: childPath, isDirectory: true, size: 0)
                } else {
                    child = buildSubtree(path: childPath, name: entry.name)
                }
                child.parent = node
                children.append(child)
                total += child.size
                count += child.fileCount
            } else if entry.isRegularFile {
                let child = FileNode(
                    name: entry.name, path: childPath, isDirectory: false,
                    size: entry.allocatedSize, inode: entry.fileID, deviceID: rootDeviceID
                )
                child.parent = node
                children.append(child)
                total += entry.allocatedSize
                count += 1
                directFileCount += 1
                directFileBytes += entry.allocatedSize
            }
        }

        node.children = children
        node.size = total
        node.fileCount = count
        reportProgress(addFiles: directFileCount, addBytes: directFileBytes, path: path)
        return node
    }

    // MARK: - Helpers

    private func reportProgress(addFiles: Int, addBytes: Int64, path: String) {
        lock.lock()
        filesScanned += addFiles
        bytesScanned += addBytes
        let now = Date()
        let due = now.timeIntervalSince(lastProgressReport) >= Self.progressThrottle
        var snapshot: Progress?
        if due {
            lastProgressReport = now
            snapshot = Progress(filesScanned: filesScanned, bytesScanned: bytesScanned, currentPath: path)
        }
        lock.unlock()
        if let snapshot { progressHandler?(snapshot) }
    }

    /// Joins a directory path and an entry name, tolerating a trailing slash on
    /// the root (e.g. "/" or "/Volumes/Disk/").
    private func join(_ dir: String, _ name: String) -> String {
        if dir.hasSuffix("/") { return dir + name }
        return dir + "/" + name
    }

    /// `st_dev` of the path's volume, or 0 if it can't be stat'd. Used to stamp
    /// file nodes so hard-link detection can key on `(device, inode)`.
    private static func deviceID(of path: String) -> UInt64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return UInt64(bitPattern: Int64(info.st_dev))
    }
}
