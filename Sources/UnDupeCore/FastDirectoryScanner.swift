import Foundation

/// One entry returned from a single directory read.
public struct DirEntry {
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    /// True only for regular files (VREG). Special files — FIFOs, sockets, block/char
    /// devices — are neither directory, symlink, nor regular; the scanner skips them
    /// so a later `FileHandle` read can never block indefinitely on one.
    public let isRegularFile: Bool
    /// Allocated size on disk in bytes (meaningful for regular files).
    public let allocatedSize: Int64
    /// Filesystem object id (inode). Used to detect hard links.
    public let fileID: UInt64
    /// True when the item is a cloud/file-provider placeholder (`SF_DATALESS`):
    /// its data lives elsewhere and occupies no local disk. Enumerating a dataless
    /// directory can trigger an on-demand download, so the scanner won't descend.
    public let isDataless: Bool
}

/// Fast, low-overhead directory enumeration using `getattrlistbulk(2)`.
///
/// `getattrlistbulk` returns the attributes of *many* directory entries in a
/// single syscall, avoiding the per-file `stat()` that `FileManager` / `readdir`
/// + `lstat` incur. On large trees this is roughly an order of magnitude faster,
/// which is what lets UnDupe scan like DaisyDisk.
///
/// The buffer layout per entry is:
///   [ UInt32 length ][ attribute_set_t returned ][ requested attrs, in bit order ]
/// We request RETURNED_ATTRS first (required), then NAME, OBJTYPE, FILEID, and the
/// file-only ALLOCSIZE. All reads are unaligned because the buffer is tightly packed.
public enum FastDirectoryScanner {

    /// vnode object types returned by ATTR_CMN_OBJTYPE.
    private enum VType: UInt32 {
        case regular = 1     // VREG
        case directory = 2   // VDIR
        case symlink = 5     // VLNK
    }

    /// 256 KB holds many hundreds of entries per syscall on typical directories.
    private static let bufferSize = 256 * 1024

    /// BSD `st_flags` bit the kernel sets on cloud/file-provider placeholders whose
    /// data is not present on local disk. Not surfaced as a Darwin constant, so we
    /// define it here. (Same value as `<sys/stat.h>`'s `SF_DATALESS`.)
    private static let datalessFlag: UInt32 = 0x4000_0000

    /// Reads all entries in the directory at `path`.
    ///
    /// Returns an empty array (never throws) when the directory cannot be opened —
    /// e.g. permission denied. Callers treat inaccessible directories as empty so a
    /// single locked folder never aborts the whole scan.
    public static func read(path: String) -> [DirEntry] {
        let fd = open(path, O_RDONLY, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr =
            UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME)
            | UInt32(ATTR_CMN_OBJTYPE) | UInt32(ATTR_CMN_FLAGS)
            | UInt32(ATTR_CMN_FILEID)
        attrList.fileattr = UInt32(ATTR_FILE_ALLOCSIZE)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var entries: [DirEntry] = []

        while true {
            let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, 0)
            if count <= 0 { break }   // 0 == finished, -1 == error (treat as done)

            var entryPtr = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                guard let parsed = parseEntry(at: entryPtr) else {
                    // Malformed entry: stop parsing this batch defensively.
                    break
                }
                entries.append(parsed.value)
                entryPtr = parsed.next
            }
        }

        return entries
    }

    /// Parses a single entry beginning at `ptr`. Returns the decoded entry plus a
    /// pointer to the next entry, or nil if the entry length is invalid.
    private static func parseEntry(at ptr: UnsafeRawPointer) -> (value: DirEntry, next: UnsafeRawPointer)? {
        var field = ptr

        let length = field.loadUnaligned(as: UInt32.self)
        guard length >= UInt32(MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size) else {
            return nil
        }
        field = field.advanced(by: MemoryLayout<UInt32>.size)

        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field = field.advanced(by: MemoryLayout<attribute_set_t>.size)

        var name = ""
        var vType: UInt32 = 0
        var flags: UInt32 = 0
        var fileID: UInt64 = 0
        var allocatedSize: Int64 = 0

        // Attributes appear in ascending bit order: NAME, OBJTYPE, FLAGS, FILEID
        // (common), then ALLOCSIZE (file). Each is present only when its returned
        // bit is set.
        if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
            let ref = field.loadUnaligned(as: attrreference_t.self)
            let namePtr = field.advanced(by: Int(ref.attr_dataoffset))
            name = String(cString: namePtr.assumingMemoryBound(to: CChar.self))
            field = field.advanced(by: MemoryLayout<attrreference_t>.size)
        }
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            vType = field.loadUnaligned(as: UInt32.self)
            field = field.advanced(by: MemoryLayout<UInt32>.size)
        }
        if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            flags = field.loadUnaligned(as: UInt32.self)
            field = field.advanced(by: MemoryLayout<UInt32>.size)
        }
        if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            fileID = field.loadUnaligned(as: UInt64.self)
            field = field.advanced(by: MemoryLayout<UInt64>.size)
        }
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            allocatedSize = field.loadUnaligned(as: Int64.self)
        }

        let entry = DirEntry(
            name: name,
            isDirectory: vType == VType.directory.rawValue,
            isSymlink: vType == VType.symlink.rawValue,
            isRegularFile: vType == VType.regular.rawValue,
            allocatedSize: allocatedSize,
            fileID: fileID,
            isDataless: (flags & datalessFlag) != 0
        )
        return (entry, ptr.advanced(by: Int(length)))
    }
}
