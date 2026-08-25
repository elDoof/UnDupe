import Foundation
import CryptoKit

/// A set of two or more files with byte-for-byte identical contents.
public struct DuplicateGroup: Identifiable {
    public let id = UUID()
    /// Size of each file in the group, in bytes.
    public let sizeBytes: Int64
    /// The identical files. Always contains at least two members.
    public let files: [FileNode]

    public init(sizeBytes: Int64, files: [FileNode]) {
        self.sizeBytes = sizeBytes
        self.files = files
    }

    /// Space that could be reclaimed by keeping one copy and trashing the rest.
    public var reclaimableBytes: Int64 {
        sizeBytes * Int64(max(0, files.count - 1))
    }
}

/// Finds duplicate files within and across one or more scanned trees.
///
/// Three-stage funnel so we never hash more than necessary:
///   1. Group by file size (files with a unique size can't have a duplicate).
///   2. Within a size group, hash only the first chunk to split obvious mismatches.
///   3. Within a matching-prefix group, confirm with a full streaming SHA-256.
/// Hashing is parallelized across size groups.
public final class DuplicateFinder {

    public struct Progress {
        public let filesHashed: Int
        public let totalToHash: Int
    }

    /// Bytes read for the cheap stage-2 prefix hash.
    private static let prefixHashBytes = 4 * 1024
    /// Chunk size for streaming full-file hashing.
    private static let streamChunkBytes = 1 * 1024 * 1024

    /// Default smallest file worth surfacing as a duplicate. Tuned for "average
    /// drive cleaning": below ~1 MB, duplicates are mostly app resources, source,
    /// and config noise that bury the few results that actually reclaim space.
    public static let defaultMinSize: Int64 = 1 * 1024 * 1024

    /// Minimum interval between progress callbacks, to avoid flooding the main
    /// queue while hashing hundreds of thousands of candidates. Mirrors
    /// `ScanEngine.progressThrottle`.
    private static let progressThrottle: TimeInterval = 0.03

    private let lock = NSLock()
    private var cancelledFlag = false
    private var hashedCount = 0
    private var lastProgressReport = Date.distantPast

    public init() {}

    public func cancel() { lock.lock(); defer { lock.unlock() }; cancelledFlag = true }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledFlag }

    /// Finds duplicate groups across the given roots.
    ///
    /// - Parameters:
    ///   - roots: one or more scanned trees (multiple = cross-drive comparison).
    ///   - minSize: ignore files smaller than this (tiny duplicates aren't worth
    ///     surfacing and dominate the result with noise). Defaults to
    ///     `defaultMinSize` (1 MB).
    ///   - progress: progress updates, called from a worker thread.
    public func find(
        in roots: [FileNode],
        minSize: Int64 = DuplicateFinder.defaultMinSize,
        progress: @escaping (Progress) -> Void
    ) -> [DuplicateGroup] {
        lock.lock(); cancelledFlag = false; hashedCount = 0; lastProgressReport = .distantPast; lock.unlock()

        // Stage 1 — group by size. Two filters keep the result focused on what a
        // user can actually clean:
        //   • size ≥ minSize — skip the long tail of tiny duplicates.
        //   • ProtectedPaths.isDeletable — skip files we'd refuse to trash anyway
        //     (inside /System, /Library, /Applications, app bundles, …). On a
        //     whole-volume scan these system/app copies are the bulk of the noise.
        // Dedupe by absolute path so the same physical file never matches itself:
        // this happens when scans overlap (e.g. Home and a folder inside it) or the
        // same volume is scanned twice, both of which would otherwise surface a file
        // as its own "duplicate".
        // Hard-link key: two paths that resolve to the same (device, inode) are
        // the same physical bytes. Collapsing them keeps hard links from being
        // surfaced as "duplicates" the user could trash to reclaim space — trashing
        // one link frees nothing while the other still references the data.
        struct HardLinkKey: Hashable { let device: UInt64; let inode: UInt64 }

        var bySize: [Int64: [FileNode]] = [:]
        var seenPaths = Set<String>()
        var seenHardLinks = Set<HardLinkKey>()
        for root in roots {
            for file in root.allFiles()
            where file.size >= minSize && ProtectedPaths.isDeletable(file.path) {
                guard seenPaths.insert(file.path).inserted else { continue }
                // Keep only one representative per inode (when known); skip further
                // hard links to the same data so they never form a fake group.
                if file.inode != 0 {
                    let key = HardLinkKey(device: file.deviceID, inode: file.inode)
                    guard seenHardLinks.insert(key).inserted else { continue }
                }
                bySize[file.size, default: []].append(file)
            }
        }
        let sizeCandidates = bySize.values.filter { $0.count > 1 }
        let totalToHash = sizeCandidates.reduce(0) { $0 + $1.count }
        if totalToHash == 0 { return [] }

        // Stages 2 & 3, run per size group in parallel.
        var results: [DuplicateGroup] = []
        let resultsLock = NSLock()

        let groups = Array(sizeCandidates)
        DispatchQueue.concurrentPerform(iterations: groups.count) { index in
            if self.isCancelled { return }
            let group = groups[index]
            let confirmed = self.confirmDuplicates(in: group, totalToHash: totalToHash, progress: progress)
            if !confirmed.isEmpty {
                resultsLock.lock(); results.append(contentsOf: confirmed); resultsLock.unlock()
            }
        }

        if isCancelled { return [] }
        // Largest reclaimable savings first.
        return results.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    // MARK: - Stages 2 & 3 for a single same-size group

    private func confirmDuplicates(
        in sameSize: [FileNode],
        totalToHash: Int,
        progress: @escaping (Progress) -> Void
    ) -> [DuplicateGroup] {
        let size = sameSize[0].size

        // Stage 2: split by prefix hash. Each file's hash work is wrapped in an
        // autoreleasepool so the per-file FileHandle and its transient buffers are
        // freed immediately, not held until this whole group finishes (see `hash`).
        var byPrefix: [Data: [FileNode]] = [:]
        for file in sameSize {
            if isCancelled { return [] }
            autoreleasepool {
                guard let prefix = Self.hash(path: file.path, maxBytes: Self.prefixHashBytes) else { return }
                byPrefix[prefix, default: []].append(file)
            }
        }

        var groups: [DuplicateGroup] = []

        // Stage 3: confirm with full hash within each prefix bucket.
        for bucket in byPrefix.values where bucket.count > 1 {
            var byFull: [Data: [FileNode]] = [:]
            for file in bucket {
                if isCancelled { return [] }
                autoreleasepool {
                    let digest = Self.hash(path: file.path, maxBytes: nil)
                    reportHashed(progress: progress, total: totalToHash)
                    guard let digest else { return }
                    byFull[digest, default: []].append(file)
                }
            }
            for identical in byFull.values where identical.count > 1 {
                groups.append(DuplicateGroup(sizeBytes: size, files: identical))
            }
        }
        return groups
    }

    private func reportHashed(progress: @escaping (Progress) -> Void, total: Int) {
        // `hashedCount` advances on every call so the running total stays exact, but
        // the callback is throttled: without this, one `DispatchQueue.main.async` per
        // hashed file floods the main queue and stalls the UI on large drives.
        lock.lock()
        hashedCount += 1
        let n = hashedCount
        let now = Date()
        let due = now.timeIntervalSince(lastProgressReport) >= Self.progressThrottle
        if due { lastProgressReport = now }
        lock.unlock()
        if due { progress(Progress(filesHashed: n, totalToHash: total)) }
    }

    // MARK: - Hashing

    /// SHA-256 of a file. When `maxBytes` is non-nil, hashes only the first
    /// `maxBytes` bytes (the cheap prefix probe). Returns nil if unreadable.
    private static func hash(path: String, maxBytes: Int?) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        var remaining = maxBytes ?? Int.max

        // Each chunk read from FileHandle is an autoreleased buffer. Without a pool
        // per iteration these accumulate for the whole file — streaming a multi-GB
        // file would then hold every 1 MB chunk in memory at once, and a parallel
        // group of large media duplicates balloons to tens of GB (the freeze bug).
        // The pool drains each chunk as soon as it's folded into the hash.
        while remaining > 0 {
            let reachedEnd: Bool = autoreleasepool {
                let want = min(remaining, streamChunkBytes)
                guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { return true }
                hasher.update(data: chunk)
                remaining -= chunk.count
                return false
            }
            if reachedEnd { break }
        }
        return Data(hasher.finalize())
    }
}
