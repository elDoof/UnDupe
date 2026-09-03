import AppKit

/// The app's single front door to the Finder and the rest of the system.
///
/// Revealing used to be hand-rolled in three different views; keeping it here
/// means every surface — the map, the inspector, the duplicate list and the
/// cleanup rows — behaves identically and gains new actions at the same time.
enum FileActions {

    /// Opens a Finder window with the item selected.
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Opens the item in whichever app owns it (a folder opens in the Finder).
    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Previews the item in the system Quick Look panel.
    static func quickLook(_ path: String) {
        QuickLookPresenter.shared.present(path: path)
    }

    /// Puts the item's absolute path on the general pasteboard.
    static func copyPath(_ path: String) {
        let pasteboard = NSPasteboard.general
        // The pasteboard keeps whatever was there until it is cleared, so a
        // stale type would survive alongside the new string.
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }
}
