import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private let model = AppState.shared.model

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let controller = MenuBarController(
            coordinator: model.coordinator,
            settingsStore: model.settingsStore,
            openSettingsHandler: { [self] in model.showSettingsWindow() }
        )

        controller.installStatusItem()
        menuBarController = controller
        model.showSettingsWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            model.showSettingsWindow()
        }

        return true
    }
}
