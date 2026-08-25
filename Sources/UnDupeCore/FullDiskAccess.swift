import Foundation

/// Detects whether the user has granted UnDupe Full Disk Access.
///
/// This matters more here than in most apps: without the grant the scanner
/// still *succeeds*, it just silently can't see into protected locations, so
/// the disk map shows a confidently wrong total with nothing to explain it.
/// Detecting the state lets the UI say so instead of quietly under-reporting.
public enum FullDiskAccess {

    /// Paths readable only with Full Disk Access. TCC's own database is the
    /// conventional probe: it is denied without the grant and, unlike Desktop
    /// or Documents, reading it never raises a consent prompt — so this check
    /// is silent and safe to run on launch.
    private static let probes = [
        "/Library/Application Support/com.apple.TCC/TCC.db",
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
    ]

    /// True when at least one protected probe path can actually be opened.
    ///
    /// Deliberately conservative: a false negative shows a dismissible hint,
    /// while a false positive would suppress the one message that explains a
    /// wrong total. Callers should treat `false` as "probably not granted"
    /// and never as grounds for blocking a scan.
    public static func isGranted() -> Bool {
        for probe in probes {
            guard FileManager.default.fileExists(atPath: probe) else { continue }
            let descriptor = open(probe, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return true
            }
        }
        return false
    }
}
