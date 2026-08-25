import Foundation
import UnDupeCore

// Headless harness for validating and benchmarking the scan engine.
//
//   undupe-scan <path>
//
// Prints total size, file count, elapsed time, and the largest top-level items —
// so the output can be sanity-checked against `du -sk <path>`.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: undupe-scan <path> | startup | extensions | junk | uninstaller\n".utf8))
    exit(2)
}

// Headless dump of the App Uninstaller module (spot-check against `ls /Applications`).
if arguments[1] == "uninstaller" {
    let apps = AppUninstaller.scan()
    let uninstallable = apps.filter { $0.canUninstall }.count
    let total = apps.reduce(Int64(0)) { $0 + $1.totalBytes }
    print("Installed apps: \(apps.count)  (uninstallable: \(uninstallable), \(ByteFormat.string(total)) total)")
    print("")
    for app in apps {
        let mark = app.canUninstall ? "●" : "🔒"
        let owner = app.owner.label.padding(toLength: 6, withPad: " ", startingAt: 0)
        let size = ByteFormat.string(app.totalBytes).padding(toLength: 10, withPad: " ", startingAt: 0)
        print("  \(mark) [\(owner)] \(size) \(app.name)")
        for leftover in app.leftovers {
            print("        + \(ByteFormat.string(leftover.sizeBytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(leftover.category): \(leftover.path)")
        }
    }
    exit(0)
}

// Headless dump of the System Junk module (spot-check against `du -sh`).
if arguments[1] == "junk" {
    let categories = JunkScanner.scan()
    let total = categories.reduce(Int64(0)) { $0 + $1.totalBytes }
    print("System junk: \(ByteFormat.string(total)) across \(categories.count) categories")
    print("")
    for category in categories {
        print("\(category.name)  (\(ByteFormat.string(category.totalBytes)))")
        for item in category.items.prefix(10) {
            print("  \(ByteFormat.string(item.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0))  \(item.name)")
        }
        print("")
    }
    exit(0)
}

// Headless dump of the Extensions module (spot-check against `pluginkit -mA`).
if arguments[1] == "extensions" {
    let items = ExtensionsScanner.scan()
    let toggleable = items.filter { $0.canToggle }.count
    let removable = items.filter { $0.canRemove }.count
    print("Extensions: \(items.count)  (toggleable: \(toggleable), removable: \(removable))")
    print("")
    for item in items {
        let mark = item.state == .disabled ? "✗" : "●"
        let owner = item.owner.label.padding(toLength: 6, withPad: " ", startingAt: 0)
        let kind = item.kind.label.padding(toLength: 16, withPad: " ", startingAt: 0)
        print("  \(mark) [\(owner)] \(kind) \(item.name)")
    }
    exit(0)
}

// Headless dump of the Startup & Background module, so the launchd scanner can be
// validated without the GUI (spot-check against `launchctl list`).
if arguments[1] == "startup" {
    let items = StartupItemsScanner.scan()
    let actionable = items.filter { $0.isActionable }.count
    print("Startup & background items: \(items.count)  (yours: \(actionable))")
    print("")
    for item in items {
        let loaded = item.isLoaded ? "●" : "○"
        let owner = item.owner.label.padding(toLength: 6, withPad: " ", startingAt: 0)
        print("  \(loaded) [\(owner)] \(item.label)")
        print("        \(item.program ?? item.plistPath)")
    }
    exit(0)
}

// Headless dump of the duplicate finder (validates the hard-link dedup: hard
// links to one inode must NOT be reported as a duplicate group; true copies must).
//   undupe-scan dups <path> [minBytes]
if arguments[1] == "dups" {
    guard arguments.count >= 3 else {
        FileHandle.standardError.write(Data("usage: undupe-scan dups <path> [minBytes]\n".utf8))
        exit(2)
    }
    let dupPath = (arguments[2] as NSString).expandingTildeInPath
    let minBytes = arguments.count >= 4 ? Int64(arguments[3]) ?? 0 : 0
    guard let root = ScanEngine().scan(rootPath: dupPath, progress: { _ in }).tree else {
        FileHandle.standardError.write(Data("scan cancelled or failed\n".utf8))
        exit(1)
    }
    let groups = DuplicateFinder().find(in: [root], minSize: minBytes, progress: { _ in })
    print("Duplicate sets: \(groups.count)")
    for group in groups {
        print("  \(group.files.count)× \(ByteFormat.string(group.sizeBytes)) each")
        for file in group.files { print("      \(file.path)  [inode \(file.inode)]") }
    }
    exit(0)
}

let path = (arguments[1] as NSString).expandingTildeInPath
let engine = ScanEngine()
let start = Date()

print("Scanning \(path) ...")
guard let root = engine.scan(rootPath: path, progress: { _ in }).tree else {
    FileHandle.standardError.write(Data("scan cancelled or failed\n".utf8))
    exit(1)
}

let elapsed = Date().timeIntervalSince(start)
print(String(format: "Done in %.2fs", elapsed))
print("Total:  \(ByteFormat.string(root.size))  (\(root.size) bytes)")
print("Files:  \(root.fileCount)")
print("KB (du-comparable): \(root.size / 1024)")
print("")
print("Largest top-level items:")
for child in root.children.prefix(15) {
    let kind = child.isDirectory ? "DIR " : "FILE"
    print("  \(kind)  \(ByteFormat.string(child.size).padding(toLength: 10, withPad: " ", startingAt: 0))  \(child.name)")
}
