import SwiftUI

@main
struct DelayDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI needs a scene, but settings live in SettingsWindowController so the app menu
        // and the menu bar item open the same window.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    AppState.shared.model.showSettingsWindow()
                }
                .keyboardShortcut(",")
            }
        }
    }
}
