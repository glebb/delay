import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject {
    private let coordinator: DelayCoordinator
    private let settingsStore: SettingsStore
    private let openSettingsHandler: () -> Void
    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()

    init(
        coordinator: DelayCoordinator,
        settingsStore: SettingsStore,
        openSettingsHandler: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.settingsStore = settingsStore
        self.openSettingsHandler = openSettingsHandler
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        bindState()
    }

    func installStatusItem() {
        if let button = statusItem.button {
            button.title = statusTitle
        }

        rebuildMenu()
    }

    private func bindState() {
        settingsStore.$delayMilliseconds
            .sink { [weak self] _ in
                self?.refreshStatusItem()
            }
            .store(in: &cancellables)

        coordinator.$statusLine
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        coordinator.$isRunning
            .sink { [weak self] _ in
                self?.refreshStatusItem()
            }
            .store(in: &cancellables)

        coordinator.$lastErrorMessage
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    private func refreshStatusItem() {
        statusItem.button?.title = statusTitle
        rebuildMenu()
    }

    private var statusTitle: String {
        let prefix = coordinator.isRunning ? "Delay On" : "Delay"
        return "\(prefix) \(settingsStore.delayMilliseconds)ms"
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let delayItem = NSMenuItem(title: "Delay: \(settingsStore.delayMilliseconds) ms", action: nil, keyEquivalent: "")
        delayItem.isEnabled = false
        menu.addItem(delayItem)

        let statusMenuItem = NSMenuItem(title: "Status: \(coordinator.statusLine)", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        if let lastErrorMessage = coordinator.lastErrorMessage {
            let errorItem = NSMenuItem(title: lastErrorMessage, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        menu.addItem(.separator())

        let toggleTitle = coordinator.isRunning ? "Stop Delayed Output" : "Start Delayed Output"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleRunning), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit DelayDisplay", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        self.statusItem.menu = menu
    }

    @objc
    private func toggleRunning() {
        coordinator.toggleRunning()
    }

    @objc
    private func openSettings() {
        openSettingsHandler()
    }

    @objc
    private func quitApplication() {
        NSApp.terminate(nil)
    }
}
