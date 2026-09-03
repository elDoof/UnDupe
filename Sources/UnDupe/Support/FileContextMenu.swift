import SwiftUI
import UnDupeCore

/// The right-click menu for anything that has a path — a treemap tile, a
/// sunburst arc, an inspector row, a duplicate. Defining it once is what keeps
/// the four surfaces from drifting apart as actions are added.
///
/// Deliberately carries no `.keyboardShortcut` modifiers: the shortcuts are
/// owned by the menu bar (`AppCommands`), and registering them a second time
/// here would mean two live handlers for the same key.
struct FileContextMenu: View {

    let path: String
    let name: String
    let sizeBytes: Int64
    let isDirectory: Bool

    /// Set when the target is somewhere the map can zoom to; `nil` hides the row.
    var onOpenInMap: (() -> Void)?
    /// A reason to block trashing on top of `ProtectedPaths` — the duplicates
    /// list uses it to protect a group's last remaining copy.
    var extraTrashBlock: String?

    let onReveal: () -> Void
    let onTrash: () -> Void

    /// Why trashing is unavailable, or `nil` when it's allowed.
    ///
    /// Asking `ProtectedPaths` up front is what lets the menu grey the action out
    /// with a reason, instead of letting the user click it and find out from a
    /// failure message afterwards. A caller-supplied block wins, because it is
    /// always the more specific of the two ("this is the last copy" beats the
    /// generic protection notice).
    static func trashBlockReason(path: String, extra: String?) -> String? {
        extra ?? ProtectedPaths.refusalReason(path)
    }

    private var trashBlockReason: String? {
        Self.trashBlockReason(path: path, extra: extraTrashBlock)
    }

    var body: some View {
        // The header names what the menu will act on. The map hit-tests whatever
        // is under the cursor, so showing the target is what makes a destructive
        // action here safe to offer.
        Section("\(name) — \(ByteFormat.string(sizeBytes))") {
            Button("Open") { FileActions.open(path) }
            Button("Quick Look") { FileActions.quickLook(path) }
            if let onOpenInMap {
                Button(isDirectory ? "Open in Map" : "Show in Map", action: onOpenInMap)
            }
        }

        Section {
            Button("Reveal in Finder", action: onReveal)
            Button("Copy Path") { FileActions.copyPath(path) }
        }

        Section {
            Button(isDirectory ? "Move Folder to Trash" : "Move to Trash", role: .destructive,
                   action: onTrash)
                .disabled(trashBlockReason != nil)
            if let reason = trashBlockReason {
                // Menu items don't reliably show tooltips, so the reason gets its
                // own (inert) row rather than hiding in a `.help`.
                Text(reason)
            }
        }
    }
}
