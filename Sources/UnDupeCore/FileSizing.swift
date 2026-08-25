import Foundation

/// Allocated-size measurement shared by the cleanup scanners (System Junk and the
/// App Uninstaller). Uses `.totalFileAllocatedSizeKey` (on-disk blocks) and sums
/// directory trees, so totals line up with `du` — with the same hard-link caveat
/// as the disk scan: blocks shared by multiple links are counted per link.
enum FileSizing {

    /// Allocated size of a file, or the summed allocated size of a directory tree.
    static func allocatedSize(of path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey, .isDirectoryKey]

        let values = try? url.resourceValues(forKeys: keys)
        if values?.isDirectory != true {
            return Int64(values?.totalFileAllocatedSize ?? 0)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        // Each enumerated URL and its resource-value lookup is autoreleased; on a
        // large cache/DerivedData tree these pile up until the walk ends. Drain them
        // per entry so sizing a huge folder stays flat in memory.
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            autoreleasepool {
                let v = try? fileURL.resourceValues(forKeys: keys)
                if v?.isRegularFile == true {
                    total += Int64(v?.totalFileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }

    /// Sizes many paths in parallel and returns a `path → bytes` map. Cache and
    /// app-support trees can be large, so the work is fanned out across cores.
    static func parallelSizes(_ paths: [String]) -> [String: Int64] {
        guard !paths.isEmpty else { return [:] }
        var results = [Int64](repeating: 0, count: paths.count)
        results.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: paths.count) { index in
                buffer[index] = allocatedSize(of: paths[index])
            }
        }
        var dict: [String: Int64] = [:]
        for (index, path) in paths.enumerated() { dict[path] = results[index] }
        return dict
    }
}
