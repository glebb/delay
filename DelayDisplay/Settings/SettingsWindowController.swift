import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settingsStore: SettingsStore
    private let coordinator: DelayCoordinator
    private var hostingController: NSHostingController<SettingsView>?

    init(settingsStore: SettingsStore, coordinator: DelayCoordinator) {
        self.settingsStore = settingsStore
        self.coordinator = coordinator
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettingsWindow() {
        let rootView = SettingsView(settingsStore: settingsStore, coordinator: coordinator)
        let hostingController = self.hostingController ?? NSHostingController(rootView: rootView)
        hostingController.rootView = rootView

        let window = self.window ?? makeWindow(contentViewController: hostingController)

        self.window = window
        self.hostingController = hostingController

        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Configured once, so reopening the window keeps wherever the user last put it.
    private func makeWindow(contentViewController: NSViewController) -> NSWindow {
        let targetContentSize = NSSize(width: 720, height: 500)
        let minimumContentSize = NSSize(width: 660, height: 420)
        let frameAutosaveName = "DelayDisplaySettingsWindow"

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: targetContentSize.width, height: targetContentSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = contentViewController
        window.title = "DelayDisplay Settings"
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentMinSize = minimumContentSize

        if !window.setFrameUsingName(frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(frameAutosaveName)

        if window.contentLayoutRect.width < minimumContentSize.width || window.contentLayoutRect.height < minimumContentSize.height {
            window.setContentSize(targetContentSize)
        }

        return window
    }
}