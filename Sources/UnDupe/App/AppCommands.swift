import SwiftUI
import UnDupeCore

/// What the map screen can do to the item the inspector is currently showing.
///
/// Menu commands live outside the view hierarchy and can't reach `ResultsView`'s
/// `@State`, so the screen hands its actions across as closures through the
/// focused-value system. A `nil` closure means the action doesn't apply right
/// now, which is what greys the matching menu item out.
struct MapActions {
    /// Named in the menu so the user can see what a command will act on.
    let targetName: String
    let quickLook: () -> Void
    let open: () -> Void
    let reveal: () -> Void
    let copyPath: () -> Void
    /// `nil` when `ProtectedPaths` refuses the target.
    let trash: (() -> Void)?
    /// `nil` at the top of the tree.
    let goUp: (() -> Void)?
}

private struct MapActionsKey: FocusedValueKey {
    typealias Value = MapActions
}

extension FocusedValues {
    var mapActions: MapActions? {
        get { self[MapActionsKey.self] }
        set { self[MapActionsKey.self] = newValue }
    }
}

/// The app's menu bar. Until now UnDupe had none, so every action was reachable
/// only by mouse; this is where the keyboard shortcuts are defined and where a
/// user goes to discover them.
struct AppCommands: Commands {

    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdateModel
    @FocusedValue(\.mapActions) private var map

    var body: some Commands {
        // Sits directly under "About UnDupe", where macOS users look for it.
        CommandGroup(after: .appInfo) {
            if updates.isSupported {
                Button("Check for Updates…") { updates.checkFromMenu() }
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Scan…") { model.reset() }
                .keyboardShortcut("n")
            Button("Rescan") { model.rescan() }
                .keyboardShortcut("r")
                .disabled(model.selectedRoot == nil)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo Move to Trash") { model.undoLastTrash() }
                .keyboardShortcut("z")
                .disabled(!model.canUndoTrash)
        }

        // Every item here needs a focused map item, so each one greys out on the
        // home and cleanup screens (`CommandMenu` itself can't be disabled).
        CommandMenu("Item") {
            // Mirrors the right-click menu's header: these commands act on
            // whatever the inspector is showing, which is worth stating.
            Text(map.map { "Selected: \($0.targetName)" } ?? "No Selection")

            Divider()

            Button("Open") { map?.open() }
                .keyboardShortcut("o")
                .disabled(map == nil)
            Button("Quick Look") { map?.quickLook() }
                // Space matches the Finder, where it is the standard preview key.
                .keyboardShortcut(.space, modifiers: [])
                .disabled(map == nil)
            Button("Show Enclosing Folder") { map?.goUp?() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(map?.goUp == nil)

            Divider()

            Button("Reveal in Finder") { map?.reveal() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(map == nil)
            Button("Copy Path") { map?.copyPath() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(map == nil)

            Divider()

            Button("Move to Trash") { map?.trash?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(map?.trash == nil)
        }
    }
}
