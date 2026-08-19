import SwiftUI

@main
struct IPAManagerApp: App {
    @StateObject private var appState = AppState()

    init() {
        AppFileManager.shared.ensureDirectoryStructure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
    }
}
