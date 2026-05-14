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
            .frame(minWidth: 660, idealWidth: 720, minHeight: 420, idealHeight: 500)
        }
    }
}
