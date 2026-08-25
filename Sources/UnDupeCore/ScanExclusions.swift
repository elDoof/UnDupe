import Foundation

/// Decides which directories the scanner should treat as opaque leaves rather
/// than crawl into. Three cases:
///
///  1. **Foreign mount points** — directories where another filesystem is mounted
///     (external drives under `/Volumes/*`, the system's auxiliary APFS volumes
///     under `/System/Volumes/*`). Crossing them would scan drives the user didn't
///     ask for; see `VolumeBoundary`.
///  2. **Dataless items** (`SF_DATALESS`): the data isn't on local disk, and
///     merely enumerating a dataless directory can trigger an on-demand download.
///  3. **Anything under `~/Library/CloudStorage/`** — the standard macOS File
///     Provider location (iCloud Drive, Dropbox, Nextcloud, OneDrive, …). Even
///     when files are materialized, every directory read is mediated by the
///     provider extension and is orders of magnitude slower than a local APFS
///     read, which can stall a whole-home scan for minutes.
///
/// Excluded directories are still represented in the tree (as zero-size nodes)
/// so the user sees them; their subtrees just aren't crawled. Cloud placeholders
/// occupy no local disk, so reporting them as ~0 local bytes is also accurate.
public enum ScanExclusions {

    /// The standard macOS File Provider replication root. Matched with leading and
    /// trailing slashes so a provider directory *inside* it is opaque, while the
    /// `CloudStorage` folder itself is still listed (one level) to show providers.
    private static let cloudStorageMarker = "/Library/CloudStorage/"

    /// True when the scanner should not descend into `entry`, located at `path`.
    ///
    /// - Parameter foreignMounts: nested mount points to treat as opaque, so the
    ///   scan stays on the volume the user chose (from `VolumeBoundary`).
    public static func shouldTreatAsOpaque(
        path: String,
        entry: DirEntry,
        foreignMounts: Set<String>
    ) -> Bool {
        guard entry.isDirectory else { return false }
        if foreignMounts.contains(path) { return true }
        if entry.isDataless { return true }
        return path.contains(cloudStorageMarker)
    }
}
