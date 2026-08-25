import Foundation

/// Computes which nested mount points the scanner must not cross, so that scanning
/// one volume (e.g. "Macintosh HD" at "/") stays *within that volume* instead of
/// descending into every other mounted drive.
///
/// On modern macOS the boot disk is presented as a single "Macintosh HD" even
/// though it is physically a read-only System volume plus a writable Data volume
/// joined by firmlinks. Both report the *same* `st_dev`, and the user's data is
/// surfaced under "/" through firmlinks rather than as a nested mount — so a plain
/// `du -x` / same-device check is unreliable here. External drives (`/Volumes/*`)
/// and the system's auxiliary APFS volumes (`/System/Volumes/VM`, `Preboot`, the
/// `/System/Volumes/Data` firmlink source, …) are each a *separate mount point*.
///
/// Treating every mount point other than the scan root as opaque therefore keeps
/// the logical volume intact (firmlinked content is followed) while stopping the
/// crawl at each foreign filesystem. Skipping `/System/Volumes/Data` also avoids
/// double-counting the Data volume, whose content already appears under "/".
public enum VolumeBoundary {

    /// Absolute paths of every currently mounted filesystem *except* `root` itself.
    /// Descending into any of these would leave the volume the user asked to scan,
    /// so the scanner treats them as opaque leaves.
    public static func foreignMountPoints(under root: String) -> Set<String> {
        let normalizedRoot = normalize(root)

        var mntbuf: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mntbuf, MNT_NOWAIT)
        guard count > 0, let mntbuf else { return [] }

        var result = Set<String>()
        for i in 0..<Int(count) {
            let mountPath = withUnsafePointer(to: mntbuf[i].f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            let normalized = normalize(mountPath)
            if normalized != normalizedRoot {
                result.insert(normalized)
            }
        }
        return result
    }

    /// Strips a trailing slash (except on "/") so mount paths compare cleanly
    /// against scanner-constructed paths, which never carry a trailing slash below
    /// the root.
    private static func normalize(_ path: String) -> String {
        if path.count > 1 && path.hasSuffix("/") { return String(path.dropLast()) }
        return path
    }
}
