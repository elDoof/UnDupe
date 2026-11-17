import Foundation

/// The rules for choosing which copies in a duplicate set get trashed.
///
/// One invariant runs through all of it: **a set never loses its last copy.**
/// It lives here, in the engine, rather than in the view that draws the
/// checkboxes, so that every route to the Trash — the batch button, a
/// right-click, anything added later — is held to it by the same code.
///
/// Marks are plain `FileNode` ids. An id that no longer appears in any group is
/// simply ignored, which is what lets a selection survive a trash followed by
/// an undo without any bookkeeping.
public enum DuplicateSelection {

    /// The selection a fresh search starts with: in each set keep the copy with
    /// the shortest path (most likely the original, least-nested one) and mark
    /// the rest. Ties break on the path itself so the choice is stable.
    public static func defaultMarks(for groups: [DuplicateGroup]) -> Set<UUID> {
        var marks: Set<UUID> = []
        for group in groups {
            guard let keeper = group.files.min(by: isPreferredKeeper) else { continue }
            for file in group.files where file !== keeper {
                marks.insert(file.id)
            }
        }
        return marks
    }

    private static func isPreferredKeeper(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
        return lhs.path < rhs.path
    }

    /// How many copies in `group` are currently set to be kept.
    public static func keptCount(in group: DuplicateGroup, marked: Set<UUID>) -> Int {
        group.files.reduce(0) { $0 + (marked.contains($1.id) ? 0 : 1) }
    }

    /// Whether `file` is the only copy in `group` still set to be kept — the
    /// one copy that may not be marked or trashed.
    public static func isLastKept(_ file: FileNode, in group: DuplicateGroup, marked: Set<UUID>) -> Bool {
        !marked.contains(file.id) && keptCount(in: group, marked: marked) == 1
    }

    /// The selection after the user clicks `file`'s checkbox. Unmarking is
    /// always allowed; marking is refused for the last kept copy, in which case
    /// the selection comes back unchanged.
    public static func toggling(
        _ file: FileNode,
        in group: DuplicateGroup,
        marked: Set<UUID>
    ) -> Set<UUID> {
        var next = marked
        if marked.contains(file.id) {
            next.remove(file.id)
        } else if !isLastKept(file, in: group, marked: marked) {
            next.insert(file.id)
        }
        return next
    }

    /// What a batch trash will actually remove.
    public struct TrashPlan {
        /// The marked files that are safe to trash.
        public let files: [FileNode]
        /// Sets left untouched because no kept copy could be found on disk.
        public let skippedGroupCount: Int
    }

    /// Works out which marked files may be trashed.
    ///
    /// The duplicate list is a snapshot from when the search ran. If the copy
    /// a set was going to keep has since been deleted or moved outside UnDupe,
    /// trashing the others would remove the last copy after all — so a set is
    /// only included when at least one of its kept copies is still on disk.
    ///
    /// - Parameter fileExists: injected so the rule can be tested without
    ///   touching the filesystem.
    public static func trashPlan(
        for groups: [DuplicateGroup],
        marked: Set<UUID>,
        fileExists: (String) -> Bool
    ) -> TrashPlan {
        var files: [FileNode] = []
        var skipped = 0
        for group in groups {
            let toTrash = group.files.filter { marked.contains($0.id) }
            guard !toTrash.isEmpty else { continue }

            let hasKeptCopyOnDisk = group.files.contains {
                !marked.contains($0.id) && fileExists($0.path)
            }
            if hasKeptCopyOnDisk {
                files.append(contentsOf: toTrash)
            } else {
                skipped += 1
            }
        }
        return TrashPlan(files: files, skippedGroupCount: skipped)
    }

    /// Whether trashing just `file` leaves another copy of it on disk.
    public static func hasOtherCopyOnDisk(
        than file: FileNode,
        in group: DuplicateGroup,
        fileExists: (String) -> Bool
    ) -> Bool {
        group.files.contains { $0 !== file && fileExists($0.path) }
    }
}
