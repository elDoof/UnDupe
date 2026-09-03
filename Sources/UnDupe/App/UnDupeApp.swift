import SwiftUI

@main
struct UnDupeApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var cleanup = CleanupModel()
    @StateObject private var updates = UpdateModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(cleanup)
                .environmentObject(updates)
                .preferredColorScheme(.dark)
                .sheet(isPresented: $updates.isSheetPresented) {
                    UpdateSheet().environmentObject(updates)
                }
                // Silent on launch: it only interrupts when there is actually a
                // newer version the user hasn't already skipped.
                .task { await updates.checkInBackground() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 740)
        // Clamp the window's minimum to ContentView's min frame, so the chrome
        // (toolbar, nav buttons) can never be shrunk off-screen.
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: model, updates: updates) }
    }
}
