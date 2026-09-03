import Foundation

/// Outcome of attempting to trash one item.
public struct TrashResult: Identifiable {
    public var id: String { path }
    /// The item's original location on disk.
    public let path: String
    public let success: Bool
    public let reclaimedBytes: Int64
    public let error: String?

    /// Where the item landed inside the Trash, when it was successfully trashed.
    /// This is the whole basis of undo: without it a "Put Back" would have to
    /// guess at the Trash filename, which macOS de-duplicates on collision.
    /// Always `nil` for a failure, and for `deletePermanently` — which really is
    /// gone.
    public let trashedURL: URL?

    /// `trashedURL` defaults to `nil` so the many call sites that report a plain
    /// failure don't have to spell out "there is nothing to put back".
    public init(
        path: String,
        success: Bool,
        reclaimedBytes: Int64,
        error: String?,
        trashedURL: URL? = nil
    ) {
        self.path = path
        self.success = success
        self.reclaimedBytes = reclaimedBytes
        self.error = error
        self.trashedURL = trashedURL
    }
}

/// Removes files the *safe* way: never `unlink`, always move to the Trash, and
/// never touch anything `ProtectedPaths` considers vital.
///
/// This is the only place in the app that removes files. Because items go to the
/// Trash, every action the user takes is recoverable until they empty it.
public enum SafeDelete {

    /// Moves the given files to the Trash, skipping protected paths.
    ///
    /// - Returns: one `TrashResult` per input file, in the same order.
    public static func moveToTrash(_ files: [FileNode]) -> [TrashResult] {
        files.map { file in
            guard ProtectedPaths.isDeletable(file.path) else {
                return refusal(path: file.path)
            }
            return trash(path: file.path, size: file.size)
        }
    }

    /// A path plus its known size, for trashing items that aren't part of a
    /// scanned `FileNode` tree — the cleanup modules deal in plists, caches, and
    /// plugin bundles discovered outside the disk scan.
    public struct TrashTarget {
        public let path: String
        public let size: Int64
        public init(path: String, size: Int64) {
            self.path = path
            self.size = size
        }
    }

    /// Path-based counterpart to the `FileNode` overload, with identical safety
    /// guarantees: never `unlink`, always the Trash, never a `ProtectedPaths` item.
    ///
    /// - Returns: one `TrashResult` per target, in the same order.
    public static func moveToTrash(_ targets: [TrashTarget]) -> [TrashResult] {
        targets.map { target in
            guard ProtectedPaths.isDeletable(target.path) else {
                return refusal(path: target.path)
            }
            return trash(path: target.path, size: target.size)
        }
    }

    /// Restores previously trashed items to where they came from — the inverse of
    /// `moveToTrash`, and the engine half of the app's undo.
    ///
    /// Only results that actually made it to the Trash can be restored, so inputs
    /// that failed (or that were deleted permanently, and so carry no
    /// `trashedURL`) come back as failures rather than being silently skipped.
    /// The Trash is the user's to manage: they may have emptied it, or something
    /// may have taken the original path in the meantime. Both are reported, not
    /// forced.
    ///
    /// - Returns: one `TrashResult` per input, in the same order, where `success`
    ///   means "this item is back at `path`". `reclaimedBytes` carries the size
    ///   that was restored, so callers can report a total.
    public static func putBack(_ results: [TrashResult]) -> [TrashResult] {
        results.map { result in
            guard result.success, let trashedURL = result.trashedURL else {
                return TrashResult(
                    path: result.path,
                    success: false,
                    reclaimedBytes: 0,
                    error: "This item was never moved to the Trash, so there's nothing to restore.",
                    trashedURL: nil
                )
            }

            let manager = FileManager.default
            let destination = URL(fileURLWithPath: result.path)

            guard manager.fileExists(atPath: trashedURL.path) else {
                return TrashResult(
                    path: result.path,
                    success: false,
                    reclaimedBytes: 0,
                    error: "It's no longer in the Trash — the Trash may have been emptied.",
                    trashedURL: nil
                )
            }
            guard !manager.fileExists(atPath: destination.path) else {
                return TrashResult(
                    path: result.path,
                    success: false,
                    reclaimedBytes: 0,
                    error: "Something else already exists at the original location.",
                    trashedURL: trashedURL
                )
            }
            // A restore never creates folders: if the enclosing folder is gone the
            // original location no longer exists, and inventing it would put the
            // item somewhere the user never had it.
            let enclosing = destination.deletingLastPathComponent().path
            guard manager.fileExists(atPath: enclosing) else {
                return TrashResult(
                    path: result.path,
                    success: false,
                    reclaimedBytes: 0,
                    error: "The folder it came from no longer exists.",
                    trashedURL: trashedURL
                )
            }

            do {
                try manager.moveItem(at: trashedURL, to: destination)
                return TrashResult(
                    path: result.path,
                    success: true,
                    reclaimedBytes: result.reclaimedBytes,
                    error: nil,
                    trashedURL: nil
                )
            } catch {
                return TrashResult(
                    path: result.path,
                    success: false,
                    reclaimedBytes: 0,
                    error: error.localizedDescription,
                    trashedURL: trashedURL
                )
            }
        }
    }

    /// Uninstalls a third-party app: trashes the whole `.app` bundle **plus** its
    /// leftover support files. The bundle is gated by the single carve-out that may
    /// trash an `.app` (`ProtectedPaths.isUninstallableApp`); the leftovers go
    /// through the normal `isDeletable` guard (they live under `~/Library`).
    /// Everything still goes to the Trash, so an uninstall is fully recoverable.
    ///
    /// - Returns: the bundle's `TrashResult` first, then one per leftover.
    public static func uninstallApp(
        bundlePath: String,
        bundleID: String?,
        bundleSize: Int64,
        leftovers: [TrashTarget]
    ) -> [TrashResult] {
        var results: [TrashResult] = []

        if ProtectedPaths.isUninstallableApp(bundlePath, bundleID: bundleID) {
            results.append(trash(path: bundlePath, size: bundleSize))
        } else {
            results.append(TrashResult(
                path: bundlePath,
                success: false,
                reclaimedBytes: 0,
                error: "This app is protected and can't be uninstalled here.",
                trashedURL: nil
            ))
        }

        results.append(contentsOf: moveToTrash(leftovers))
        return results
    }

    /// **Permanently** deletes the given targets (skipping the Trash), still
    /// refusing anything `ProtectedPaths` considers vital. This is the one path
    /// that is *not* reversible, so it is opt-in only — surfaced solely by the
    /// Automatic Cleanup sheet when the user explicitly asks to skip the Trash,
    /// and confined to the same allowlisted, regenerable junk. Callers MUST
    /// confirm intent before calling it.
    ///
    /// Results always carry `trashedURL: nil`: there is nothing to put back.
    ///
    /// - Returns: one `TrashResult` per target, in the same order.
    public static func deletePermanently(_ targets: [TrashTarget]) -> [TrashResult] {
        targets.map { target in
            guard ProtectedPaths.isDeletable(target.path) else {
                return refusal(path: target.path)
            }

            let url = URL(fileURLWithPath: target.path)
            do {
                try FileManager.default.removeItem(at: url)
                return TrashResult(
                    path: target.path,
                    success: true,
                    reclaimedBytes: target.size,
                    error: nil,
                    trashedURL: nil
                )
            } catch {
                return TrashResult(
                    path: target.path,
                    success: false,
                    reclaimedBytes: 0,
                    error: error.localizedDescription,
                    trashedURL: nil
                )
            }
        }
    }

    // MARK: - Internal

    /// Moves a single already-vetted path to the Trash, recording where it landed
    /// so it can be put back. Callers must run the appropriate `ProtectedPaths`
    /// guard *before* calling this.
    private static func trash(path: String, size: Int64) -> TrashResult {
        let url = URL(fileURLWithPath: path)
        do {
            var landed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
            return TrashResult(
                path: path,
                success: true,
                reclaimedBytes: size,
                error: nil,
                trashedURL: landed as URL?
            )
        } catch {
            return TrashResult(
                path: path,
                success: false,
                reclaimedBytes: 0,
                error: error.localizedDescription,
                trashedURL: nil
            )
        }
    }

    /// The standard result for a path `ProtectedPaths` refuses.
    private static func refusal(path: String) -> TrashResult {
        TrashResult(
            path: path,
            success: false,
            reclaimedBytes: 0,
            error: ProtectedPaths.refusalReason(path),
            trashedURL: nil
        )
    }
}
