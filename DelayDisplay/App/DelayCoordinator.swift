import AppKit
import CoreVideo
import Foundation
import QuartzCore

@MainActor
final class DelayCoordinator: ObservableObject {
    private static let liveModeAccessibilityMessage = "Temporary live mode in other apps requires Accessibility access in System Settings > Privacy & Security > Accessibility."

    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var statusLine = "Idle"
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var availableDisplays: [CapturedDisplayOption] = []
    @Published private(set) var isRefreshingDisplays = false
    @Published private(set) var displaySelectionMessage: String?
    @Published private(set) var availableWindows: [CapturedWindowOption] = []
    @Published private(set) var isRefreshingWindows = false
    @Published private(set) var windowSelectionMessage: String?

    private let settingsStore: SettingsStore
    private let permissionsService: PermissionsService
    private let screenCaptureService: ScreenCaptureService
    private let overlayWindowController: OverlayWindowController
    private let presentationTicker = PresentationTicker()
    private lazy var overlayHotkeyMonitor = OverlayHotkeyMonitor(
        onKeyActivity: { [weak self] in
            self?.handleObservedKeyPress()
        },
        shouldHandleKeyActivity: { [weak self] in
            guard let self else {
                return false
            }

            return self.isRunning && self.settingsStore.liveModeOnKeyPressEnabled
        }
    )
    private var liveModeResetTask: Task<Void, Never>?
    private var isTemporaryLiveModeActive = false
    private var lastPresentedDelayMilliseconds: Int?
    private var lastPresentedStatusLine: String?

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

    deinit {
        liveModeResetTask?.cancel()
        presentationTicker.stop()
    }

    func start() async {
        guard !isRunning, !isBusy else { return }

        resetTemporaryLiveModeState()

        isBusy = true
        lastErrorMessage = nil
        statusLine = permissionsService.hasScreenRecordingPermission()
            ? "Preparing capture source"
            : "Requesting screen recording permission"
        refreshKeyboardActivityPermission(prompt: true)

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
                qualityPreset: settingsStore.captureQualityPreset,
                selectedDisplayID: settingsStore.selectedDisplayID,
                selectedWindowID: settingsStore.selectedWindowID
            )

            guard let screen = NSScreen.screen(withDisplayID: bootstrap.displayID) ?? NSScreen.main else {
                throw DelayCoordinatorError.noMatchingScreen
            }

            let initialStatusLine = currentStatusLine(isWarmingUp: true)

            let presentationMode: PresentationMode = settingsStore.captureMode == .frontmostWindowFullscreen
                ? .fullscreenWindow
                : .previewWindow

            statusLine = "Opening delayed output window"
            NSApp.setActivationPolicy(.regular)

            overlayWindowController.showOverlay(
                on: screen,
                delayMilliseconds: effectiveDelayMilliseconds,
                statusLine: initialStatusLine,
                presentationMode: presentationMode,
                showsDebugHUD: settingsStore.showsDebugHUD,
                keepsOverlayOnTop: settingsStore.keepsOverlayOnTop
            )

            statusLine = "Starting capture stream"

            try await screenCaptureService.startCapture(
                bootstrap: bootstrap,
                delayMilliseconds: effectiveDelayMilliseconds,
                qualityPreset: settingsStore.captureQualityPreset,
                excludingBundleIdentifier: Bundle.main.bundleIdentifier,
                overlayWindowID: overlayWindowController.overlayWindowID
            )

            isRunning = true
            lastPresentedDelayMilliseconds = effectiveDelayMilliseconds
            lastPresentedStatusLine = initialStatusLine
            startPresentationTicker(
                displayID: screen.displayID,
                framesPerSecond: settingsStore.captureQualityPreset.presentationFramesPerSecond
            )
            overlayHotkeyMonitor.start()
            statusLine = initialStatusLine
        } catch {
            resetTemporaryLiveModeState()
            presentationTicker.stop()
            overlayWindowController.hideOverlay()
            NSApp.setActivationPolicy(.accessory)
            statusLine = "Unable to prepare capture"
            lastErrorMessage = error.localizedDescription
        }
    }

    func stop() {
        guard isRunning else { return }

        resetTemporaryLiveModeState()
        presentationTicker.stop()
        overlayHotkeyMonitor.stop()
        overlayWindowController.hideOverlay()
        screenCaptureService.stopCapture()
        NSApp.setActivationPolicy(.accessory)
        isRunning = false
        lastPresentedDelayMilliseconds = nil
        lastPresentedStatusLine = nil
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

        applyEffectiveDelay(isWarmingUp: false)
    }

    func applyUpdatedCaptureConfiguration() {
        guard isRunning else {
            return
        }

        stop()

        Task {
            await start()
        }
    }

    func applyUpdatedPresentationSettings() {
        guard isRunning else { return }

        overlayWindowController.updatePresentation(
            showsDebugHUD: settingsStore.showsDebugHUD,
            keepsOverlayOnTop: settingsStore.keepsOverlayOnTop
        )
    }

    func applyUpdatedKeyboardActivitySetting() {
        if settingsStore.liveModeOnKeyPressEnabled {
            refreshKeyboardActivityPermission(prompt: true)
            if isRunning {
                overlayHotkeyMonitor.refresh()
            }
            return
        }

        clearKeyboardActivityPermissionMessageIfNeeded()

        guard isRunning else { return }

        if !settingsStore.liveModeOnKeyPressEnabled {
            deactivateTemporaryLiveModeIfNeeded()
        }
    }

    func applyUpdatedLiveModeGracePeriod() {
        guard isRunning, isTemporaryLiveModeActive else {
            return
        }

        scheduleTemporaryLiveModeReset()
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

    func refreshAvailableDisplays(requestPermission: Bool = false) async {
        guard !isRefreshingDisplays else { return }

        isRefreshingDisplays = true
        defer {
            isRefreshingDisplays = false
        }

        if requestPermission {
            let granted = permissionsService.requestScreenRecordingPermissionIfNeeded()
            guard granted else {
                availableDisplays = []
                displaySelectionMessage = "Grant Screen Recording access in System Settings > Privacy & Security, then quit and relaunch DelayDisplay."
                return
            }
        } else if !permissionsService.hasScreenRecordingPermission() {
            availableDisplays = []
            displaySelectionMessage = "Grant Screen Recording access, relaunch DelayDisplay, then refresh to load monitors."
            return
        }

        do {
            let displays = try await screenCaptureService.availableDisplays()

            availableDisplays = displays
            displaySelectionMessage = displays.isEmpty
                ? "No shareable monitors are currently available."
                : nil

            if let selectedDisplayID = settingsStore.selectedDisplayID,
               displays.contains(where: { $0.id == selectedDisplayID }) {
                return
            }

            settingsStore.setSelectedDisplayID(displays.first?.id)
        } catch {
            availableDisplays = []
            displaySelectionMessage = error.localizedDescription
        }
    }

    private var effectiveDelayMilliseconds: Int {
        isTemporaryLiveModeActive ? SettingsStore.minimumDelay : settingsStore.delayMilliseconds
    }

    private func handleObservedKeyPress() {
        guard isRunning, settingsStore.liveModeOnKeyPressEnabled else {
            return
        }

        isTemporaryLiveModeActive = true
        scheduleTemporaryLiveModeReset()
        applyEffectiveDelay(isWarmingUp: false)
    }

    private func scheduleTemporaryLiveModeReset() {
        liveModeResetTask?.cancel()
        liveModeResetTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.liveModeTimeoutNanoseconds ?? 0)
            } catch {
                return
            }

            await MainActor.run {
                self?.deactivateTemporaryLiveModeIfNeeded()
            }
        }
    }

    private func deactivateTemporaryLiveModeIfNeeded() {
        liveModeResetTask?.cancel()
        liveModeResetTask = nil

        guard isTemporaryLiveModeActive else {
            return
        }

        isTemporaryLiveModeActive = false
        applyEffectiveDelay(isWarmingUp: false)
    }

    private func resetTemporaryLiveModeState() {
        liveModeResetTask?.cancel()
        liveModeResetTask = nil
        isTemporaryLiveModeActive = false
    }

    private func applyEffectiveDelay(isWarmingUp: Bool) {
        let runtimeStatus = currentStatusLine(isWarmingUp: isWarmingUp)
        let effectiveDelay = effectiveDelayMilliseconds

        screenCaptureService.updateDelay(effectiveDelay)
        lastPresentedDelayMilliseconds = effectiveDelay
        lastPresentedStatusLine = runtimeStatus
        overlayWindowController.update(
            delayMilliseconds: effectiveDelay,
            statusLine: runtimeStatus
        )
        statusLine = runtimeStatus
    }

    private func startPresentationTicker(displayID: CGDirectDisplayID?, framesPerSecond: Int) {
        let screenCaptureService = self.screenCaptureService

        presentationTicker.start(displayID: displayID, fallbackFramesPerSecond: framesPerSecond) { [weak self, screenCaptureService] hostTime in
            guard let self,
                  let presentation = await screenCaptureService.presentation(atHostTime: hostTime) else {
                return
            }

            await MainActor.run {
                guard self.isRunning else {
                    return
                }

                self.presentCurrentFrame(presentation)
            }
        }
    }

    private func presentCurrentFrame(_ presentation: CapturePresentation) {
        let runtimeStatus = currentStatusLine(isWarmingUp: presentation.isWarmingUp)
        let effectiveDelay = effectiveDelayMilliseconds

        if statusLine != runtimeStatus {
            statusLine = runtimeStatus
        }

        if lastPresentedDelayMilliseconds != effectiveDelay || lastPresentedStatusLine != runtimeStatus {
            lastPresentedDelayMilliseconds = effectiveDelay
            lastPresentedStatusLine = runtimeStatus
            overlayWindowController.update(
                delayMilliseconds: effectiveDelay,
                statusLine: runtimeStatus
            )
        }

        overlayWindowController.display(
            frame: presentation.image,
            isWarmingUp: presentation.isWarmingUp,
            debugInfo: presentation.debugInfo
        )
    }

    private func currentStatusLine(isWarmingUp: Bool) -> String {
        if isTemporaryLiveModeActive {
            let baseDelay = settingsStore.delayMilliseconds
            if isWarmingUp {
                return "Warming up live mode at 0 ms (returns to \(baseDelay) ms)"
            }

            return "Live mode at 0 ms (returns to \(baseDelay) ms)"
        }

        let delayMilliseconds = settingsStore.delayMilliseconds
        switch settingsStore.captureMode {
        case .displayPreview:
            return isWarmingUp
                ? "Warming up \(delayMilliseconds) ms buffer"
                : "Running at \(delayMilliseconds) ms"
        case .frontmostWindowFullscreen:
            return isWarmingUp
                ? "Warming up selected window at \(delayMilliseconds) ms"
                : "Running selected window at \(delayMilliseconds) ms"
        }
    }

    private func refreshKeyboardActivityPermission(prompt: Bool) {
        guard settingsStore.liveModeOnKeyPressEnabled else {
            clearKeyboardActivityPermissionMessageIfNeeded()
            return
        }

        let isGranted = permissionsService.requestAccessibilityPermissionIfNeeded(prompt: prompt)
        if isGranted {
            clearKeyboardActivityPermissionMessageIfNeeded()
        } else {
            lastErrorMessage = Self.liveModeAccessibilityMessage
        }
    }

    private func clearKeyboardActivityPermissionMessageIfNeeded() {
        if lastErrorMessage == Self.liveModeAccessibilityMessage {
            lastErrorMessage = nil
        }
    }

    private var liveModeTimeoutNanoseconds: UInt64 {
        UInt64(settingsStore.liveModeGracePeriodSeconds) * 1_000_000_000
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

private final class PresentationTicker {
    private let callbackQueue = DispatchQueue(label: "DelayDisplay.PresentationTicker")
    private let clock = ContinuousClock()
    private var task: Task<Void, Never>?
    private var displayLink: CVDisplayLink?
    private var pendingHostTime: TimeInterval?
    private var isTickInFlight = false
    private var tick: (@Sendable (TimeInterval) async -> Void)?

    func start(
        displayID: CGDirectDisplayID?,
        fallbackFramesPerSecond: Int = 60,
        tick: @escaping @Sendable (TimeInterval) async -> Void
    ) {
        stop()
        self.tick = tick

        if let displayID,
           startDisplayLink(displayID: displayID) {
            return
        }

        startFallbackTicker(framesPerSecond: fallbackFramesPerSecond)
    }

    private func startFallbackTicker(framesPerSecond: Int) {
        guard let tick else {
            return
        }

        let normalizedFramesPerSecond = max(framesPerSecond, 1)
        let intervalNanoseconds = max(Int64(1_000_000_000 / normalizedFramesPerSecond), 1)
        let interval = Duration.nanoseconds(intervalNanoseconds)
        let tolerance = Duration.nanoseconds(max(intervalNanoseconds / 10, 500_000))

        task = Task {
            var nextTick = clock.now

            while !Task.isCancelled {
                await tick(CACurrentMediaTime())
                nextTick += interval

                do {
                    try await clock.sleep(until: nextTick, tolerance: tolerance)
                } catch {
                    break
                }
            }
        }
    }

    func stop() {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }

        displayLink = nil
        task?.cancel()
        task = nil
        callbackQueue.sync {
            pendingHostTime = nil
            isTickInFlight = false
        }
        tick = nil
    }

    deinit {
        stop()
    }

    private func startDisplayLink(displayID: CGDirectDisplayID) -> Bool {
        var displayLink: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &displayLink) == kCVReturnSuccess,
              let displayLink else {
            return false
        }

        guard CVDisplayLinkSetOutputHandler(displayLink, { [weak self] _, _, outputTime, _, _ in
            self?.handleDisplayLinkTick(hostTime: outputTime.pointee.hostTime)
            return kCVReturnSuccess
        }) == kCVReturnSuccess else {
            return false
        }

        guard CVDisplayLinkStart(displayLink) == kCVReturnSuccess else {
            return false
        }

        self.displayLink = displayLink
        return true
    }

    private func handleDisplayLinkTick(hostTime: UInt64) {
        let hostTimeSeconds = seconds(forHostTime: hostTime)

        callbackQueue.async { [weak self] in
            guard let self else {
                return
            }

            if self.isTickInFlight {
                self.pendingHostTime = hostTimeSeconds
                return
            }

            self.scheduleTick(hostTime: hostTimeSeconds)
        }
    }

    private func scheduleTick(hostTime: TimeInterval) {
        guard let tick else {
            return
        }

        isTickInFlight = true

        Task { [weak self] in
            await tick(hostTime)
            self?.finishTick()
        }
    }

    private func finishTick() {
        callbackQueue.async { [weak self] in
            guard let self else {
                return
            }

            if let pendingHostTime {
                self.pendingHostTime = nil
                self.scheduleTick(hostTime: pendingHostTime)
                return
            }

            self.isTickInFlight = false
        }
    }

    private func seconds(forHostTime hostTime: UInt64) -> TimeInterval {
        let frequency = CVGetHostClockFrequency()
        guard hostTime > 0,
              frequency > 0 else {
            return CACurrentMediaTime()
        }

        return Double(hostTime) / frequency
    }
}
