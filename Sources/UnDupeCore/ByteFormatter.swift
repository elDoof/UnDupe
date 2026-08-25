import Foundation

/// Humanized byte-size formatting shared across the engine, CLI, and UI.
public enum ByteFormat {

    /// Renders a byte count as a short human string, e.g. "1.4 GB", "920 KB".
    ///
    /// Uses base-1000 units (KB/MB/GB) to match Finder's "About This Mac"
    /// storage reporting, which is what users expect to see.
    public static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }

    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file          // base-1000, matches Finder
        f.allowsNonnumericFormatting = false
        return f
    }()
}
