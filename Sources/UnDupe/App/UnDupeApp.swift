import SwiftUI

@main
struct UnDupeApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var cleanup = CleanupModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(cleanup)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 740)
        // Clamp the window's minimum to ContentView's min frame, so the chrome
        // (toolbar, nav buttons) can never be shrunk off-screen.
        .windowResizability(.contentMinSize)
    }
}
