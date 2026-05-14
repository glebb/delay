import AppKit
import Foundation

@MainActor
final class DelayCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var statusLine = "Idle"
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var availableWindows: [CapturedWindowOption] = []
    @Published private(set) var isRefreshingWindows = false
    @Published private(set) var windowSelectionMessage: String?

    private let settingsStore: SettingsStore
    private let permissionsService: PermissionsService
    private let screenCaptureService: ScreenCaptureService
    private let overlayWindowController: OverlayWindowController
    private lazy var overlayHotkeyMonitor = OverlayHotkeyMonitor { [weak self] in
        self?.stop()
    }

    init(
        settingsStore: SettingsStore,
        permissionsService: PermissionsService,
        screenCaptureService: ScreenCaptureService,
        overlayWindowController: OverlayWindowController
    ) {
        self.settingsStore = settingsStore
        self.permissionsService = permissionsService
        self.screenCaptureService = screenCaptureService
        self.overlayWindowController = overlayWindowController
        self.overlayWindowController.onUserClose = { [weak self] in
            self?.stop()
        }
    }

    func start() async {
        guard !isRunning, !isBusy else { return }

        isBusy = true
        lastErrorMessage = nil
        statusLine = permissionsService.hasScreenRecordingPermission()
            ? "Preparing capture source"
            : "Requesting screen recording permission"

        defer {
            isBusy = false
        }

        let isGranted = permissionsService.requestScreenRecordingPermissionIfNeeded()
        guard isGranted else {
            statusLine = "Screen recording permission required"
            lastErrorMessage = "Grant Screen Recording access in System Settings > Privacy & Security, then quit and relaunch DelayDisplay."
            return
        }

        do {
            statusLine = "Preparing capture source"

            let bootstrap = try await screenCaptureService.prepareBootstrap(
                excludingBundleIdentifier: Bundle.main.bundleIdentifier,
                captureMode: settingsStore.captureMode,
                selectedWindowID: settingsStore.selectedWindowID
            )

            guard let screen = NSScreen.screen(withDisplayID: bootstrap.displayID) ?? NSScreen.main else {
                throw DelayCoordinatorError.noMatchingScreen
            }

            let initialStatusLine = settingsStore.captureMode == .frontmostWindowFullscreen
                ? "Warming up selected window at \(settingsStore.delayMilliseconds) ms"
                : "Warming up \(settingsStore.delayMilliseconds) ms buffer"

            let presentationMode: PresentationMode = settingsStore.captureMode == .frontmostWindowFullscreen
                ? .fullscreenWindow
                : .previewWindow

            statusLine = "Opening delayed output window"
            NSApp.setActivationPolicy(.regular)

            overlayWindowController.showOverlay(
                on: screen,
                delayMilliseconds: settingsStore.delayMilliseconds,
                statusLine: initialStatusLine,
                presentationMode: presentationMode,
                showsDebugHUD: settingsStore.showsDebugHUD
            )

            statusLine = "Starting capture stream"

            try await screenCaptureService.startCapture(
                bootstrap: bootstrap,
                delayMilliseconds: settingsStore.delayMilliseconds,
                excludingBundleIdentifier: Bundle.main.bundleIdentifier,
                overlayWindowID: overlayWindowController.overlayWindowID
            ) { [weak self] image, isWarmingUp, debugInfo in
                guard let self else { return }

                await MainActor.run {
                    let runtimeStatus = isWarmingUp
                        ? "Warming up \(self.settingsStore.delayMilliseconds) ms buffer"
                        : "Running at \(self.settingsStore.delayMilliseconds) ms"

                    self.statusLine = runtimeStatus
                    self.overlayWindowController.update(
                        delayMilliseconds: self.settingsStore.delayMilliseconds,
                        statusLine: runtimeStatus
                    )
                    self.overlayWindowController.display(frame: image, isWarmingUp: isWarmingUp, debugInfo: debugInfo)
                }
            }

            overlayHotkeyMonitor.start()
            isRunning = true
            statusLine = initialStatusLine
        } catch {
            overlayWindowController.hideOverlay()
            NSApp.setActivationPolicy(.accessory)
            statusLine = "Unable to prepare capture"
            lastErrorMessage = error.localizedDescription
        }
    }

    func stop() {
        guard isRunning else { return }

        overlayHotkeyMonitor.stop()
        overlayWindowController.hideOverlay()
        screenCaptureService.stopCapture()
        NSApp.setActivationPolicy(.accessory)
        isRunning = false
        statusLine = "Idle"
        lastErrorMessage = nil
    }

    func toggleRunning() {
        if isRunning {
            stop()
            return
        }

        Task {
            await start()
        }
    }

    func applyUpdatedDelay() {
        guard isRunning else { return }

        screenCaptureService.updateDelay(settingsStore.delayMilliseconds)

        overlayWindowController.update(
            delayMilliseconds: settingsStore.delayMilliseconds,
            statusLine: "Running at \(settingsStore.delayMilliseconds) ms"
        )
        statusLine = "Running at \(settingsStore.delayMilliseconds) ms"
    }

    func applyUpdatedPresentationSettings() {
        guard isRunning else { return }

        overlayWindowController.updatePresentation(showsDebugHUD: settingsStore.showsDebugHUD)
    }

    func refreshAvailableWindows(requestPermission: Bool = false) async {
        guard !isRefreshingWindows else { return }

        isRefreshingWindows = true
        defer {
            isRefreshingWindows = false
        }

        if requestPermission {
            let granted = permissionsService.requestScreenRecordingPermissionIfNeeded()
            guard granted else {
                availableWindows = []
                windowSelectionMessage = "Grant Screen Recording access in System Settings > Privacy & Security, then quit and relaunch DelayDisplay."
                return
            }
        } else if !permissionsService.hasScreenRecordingPermission() {
            availableWindows = []
            windowSelectionMessage = "Grant Screen Recording access, relaunch DelayDisplay, then refresh to load windows."
            return
        }

        do {
            let windows = try await screenCaptureService.availableWindows(
                excludingBundleIdentifier: Bundle.main.bundleIdentifier
            )

            availableWindows = windows
            windowSelectionMessage = windows.isEmpty
                ? "No eligible app windows are currently available."
                : nil

            if let selectedWindowID = settingsStore.selectedWindowID,
               windows.contains(where: { $0.id == selectedWindowID }) {
                return
            }

            settingsStore.setSelectedWindowID(windows.first?.id)
        } catch {
            availableWindows = []
            windowSelectionMessage = error.localizedDescription
        }
    }
}

enum DelayCoordinatorError: LocalizedError {
    case noMatchingScreen

    var errorDescription: String? {
        switch self {
        case .noMatchingScreen:
            return "The selected display could not be mapped to an active screen."
        }
    }
}

private extension NSScreen {
    static func screen(withDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }

            return CGDirectDisplayID(screenNumber.uint32Value) == displayID
        }
    }
}
