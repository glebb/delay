import SwiftUI

@main
struct DelayDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                settingsStore: AppState.shared.model.settingsStore,
                coordinator: AppState.shared.model.coordinator
            )
            .frame(width: 360)
        }
    }
}
