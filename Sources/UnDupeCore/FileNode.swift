import Foundation

/// A node in the scanned filesystem tree.
///
/// This is a reference type by design: the tree is built incrementally during
/// a scan (sizes accumulate up the hierarchy), and SwiftUI selection/identity
/// works naturally with a stable object identity. Once a scan completes the
/// tree is treated as read-only by the UI.
public final class FileNode: Identifiable {

    public let id = UUID()
    public let name: String
    public let path: String
    public let isDirectory: Bool

    /// Allocated size on disk in bytes. For directories this is the sum of all
    /// descendants (computed during the scan). For files it is the file's own
    /// allocated size.
    public internal(set) var size: Int64

    /// Direct children, sorted largest-first once the scan finalizes the node.
    public internal(set) var children: [FileNode]

    /// Number of files contained at or below this node (directories excluded).
    public internal(set) var fileCount: Int

    /// Filesystem object id (inode) for file nodes, 0 when unknown (directories,
    /// opaque/cloud leaves). Combined with `deviceID` it identifies the physical
    /// file behind a path, so the duplicate finder can tell hard links (same
    /// inode, different path) apart from true content duplicates.
    public let inode: UInt64

    /// Device id of the volume this node lives on, 0 when unknown. Inode numbers
    /// are only unique per device, so hard-link detection keys on the pair.
    public let deviceID: UInt64

    public weak var parent: FileNode?

    init(
        name: String,
        path: String,
        isDirectory: Bool,
        size: Int64,
        inode: UInt64 = 0,
        deviceID: UInt64 = 0
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.inode = inode
        self.deviceID = deviceID
        self.children = []
        self.fileCount = isDirectory ? 0 : 1
    }

    /// Fraction of the given total this node represents (0...1).
    public func fraction(of total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return Double(size) / Double(total)
    }

    /// Depth-first collection of every file (non-directory) leaf beneath this node.
    /// Used by the duplicate finder.
    public func allFiles() -> [FileNode] {
        var result: [FileNode] = []
        var stack: [FileNode] = [self]
        while let node = stack.popLast() {
            if node.isDirectory {
                stack.append(contentsOf: node.children)
            } else {
                result.append(node)
            }
        }
        return result
    }

    /// Removes this node from its parent and subtracts its size and file count
    /// from every ancestor. Called after a file is trashed so the visualization
    /// reflects the freed space without a full re-scan.
    public func detachFromParent() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }

        let sizeDelta = size
        let countDelta = fileCount
        var ancestor: FileNode? = parent
        while let node = ancestor {
            node.size -= sizeDelta
            node.fileCount -= countDelta
            ancestor = node.parent
        }
        self.parent = nil
    }

    /// Puts this node back under `parent`, adding its size and file count back to
    /// every ancestor — the exact inverse of `detachFromParent()`, used when the
    /// user undoes a trash so the map returns to what it showed before.
    ///
    /// A node that still has a parent is ignored: re-adding an attached node would
    /// double-count it up the whole ancestor chain.
    public func reattach(to parent: FileNode) {
        guard self.parent == nil else { return }

        self.parent = parent
        parent.children.append(self)
        // Children are held largest-first (see `sortDescendingBySize`), and both
        // the treemap and the inspector's LARGEST ITEMS list rely on that order.
        parent.children.sort { $0.size > $1.size }

        let sizeDelta = size
        let countDelta = fileCount
        var ancestor: FileNode? = parent
        while let node = ancestor {
            node.size += sizeDelta
            node.fileCount += countDelta
            ancestor = node.parent
        }
    }

    /// Sorts children largest-first, recursively. Called once when a scan finishes.
    func sortDescendingBySize() {
        children.sort { $0.size > $1.size }
        for child in children where child.isDirectory {
            child.sortDescendingBySize()
        }
    }
}
