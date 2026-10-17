import AppKit
import SwiftUI

enum PresentationMode {
    case previewWindow
    case fullscreenWindow
}

private final class OverlayWindow: NSWindow {
    private static let escapeKeyCode: UInt16 = 53

    var onEscapeKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Intercepted before the hosting view sees the event, so Escape stops output regardless
    // of which view is first responder.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.keyCode == Self.escapeKeyCode,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           let onEscapeKey {
            onEscapeKey()
            return
        }

        super.sendEvent(event)
    }
}

@MainActor
final class OverlayWindowController: NSWindowController, NSWindowDelegate {
    private let contentModel = OverlayContentModel()
    private var hostingController: NSHostingController<DelayedFrameView>?
    private var currentPresentationMode: PresentationMode = .previewWindow
    private var keepsOverlayOnTop = false
    private let initialDebugInfo = CaptureDebugInfo(
        receivedFrames: 0,
        acceptedFrames: 0,
        emittedFrames: 0,
        skippedFrames: 0,
        lateFrameCount: 0,
        bufferedFrames: 0,
        bufferedDurationMilliseconds: 0,
        effectiveDelayMilliseconds: nil,
        captureFramesPerSecond: 0,
        presentationFramesPerSecond: 0,
        qualityPresetDescription: "Balanced",
        latestImageDescription: "n/a"
    )
    var onUserClose: (() -> Void)?

    func showOverlay(
        on screen: NSScreen,
        delayMilliseconds: Int,
        statusLine: String,
        presentationMode: PresentationMode,
        showsDebugHUD: Bool,
        keepsOverlayOnTop: Bool
    ) {
        contentModel.update(delayMilliseconds: delayMilliseconds, statusLine: statusLine)
        updatePresentation(showsDebugHUD: showsDebugHUD, keepsOverlayOnTop: keepsOverlayOnTop)
        contentModel.updatePlayback(
            framesToEnqueue: [],
            delayMilliseconds: delayMilliseconds,
            shouldResetRenderer: true,
            isWarmingUp: true,
            debugInfo: initialDebugInfo
        )
        currentPresentationMode = presentationMode

        let rootView = DelayedFrameView(model: contentModel)
        let hostingController = NSHostingController(rootView: rootView)
        let window: OverlayWindow

        switch presentationMode {
        case .previewWindow:
            let frame = previewFrame(for: screen)
            window = OverlayWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.setFrame(frame, display: true)
            window.ignoresMouseEvents = false
            window.title = windowTitle(delayMilliseconds: delayMilliseconds, statusLine: statusLine, presentationMode: presentationMode)
            window.titleVisibility = .visible
            window.minSize = NSSize(width: 480, height: 270)
            window.hasShadow = true
        case .fullscreenWindow:
            let frame = centeredOutputFrame(for: screen)
            window = OverlayWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.setFrame(frame, display: true)
            window.ignoresMouseEvents = false
            window.title = windowTitle(delayMilliseconds: delayMilliseconds, statusLine: statusLine, presentationMode: presentationMode)
            window.titleVisibility = .visible
            window.hasShadow = true
            window.minSize = NSSize(width: 640, height: 360)
        }

        self.window?.orderOut(nil)

        window.contentViewController = hostingController
        window.backgroundColor = .black
        window.isOpaque = true
        window.delegate = self
        window.onEscapeKey = { [weak self] in
            self?.onUserClose?()
        }
        window.isReleasedWhenClosed = false
        applyPresentationBehavior(to: window)

        self.window = window
        self.hostingController = hostingController

        showWindow(nil)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(delayMilliseconds: Int, statusLine: String) {
        contentModel.update(delayMilliseconds: delayMilliseconds, statusLine: statusLine)
        let updatedTitle = windowTitle(
            delayMilliseconds: delayMilliseconds,
            statusLine: statusLine,
            presentationMode: currentPresentationMode
        )

        if window?.title != updatedTitle {
            window?.title = updatedTitle
        }
    }

    func updatePresentation(showsDebugHUD: Bool, keepsOverlayOnTop: Bool) {
        contentModel.updatePresentation(showsDebugHUD: showsDebugHUD)
        self.keepsOverlayOnTop = keepsOverlayOnTop

        guard let window else {
            return
        }

        applyPresentationBehavior(to: window)
    }

    func display(
        framesToEnqueue: [DelayedFramePayload],
        delayMilliseconds: Int,
        shouldResetRenderer: Bool,
        isWarmingUp: Bool,
        debugInfo: CaptureDebugInfo
    ) {
        contentModel.updatePlayback(
            framesToEnqueue: framesToEnqueue,
            delayMilliseconds: delayMilliseconds,
            shouldResetRenderer: shouldResetRenderer,
            isWarmingUp: isWarmingUp,
            debugInfo: debugInfo
        )
    }

    func hideOverlay() {
        contentModel.reset()
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender.styleMask.contains(.closable) {
            onUserClose?()
        }
        return false
    }

    private func previewFrame(for screen: NSScreen) -> CGRect {
        let visibleFrame = screen.visibleFrame
        let displayAspectRatio = screen.frame.width / max(screen.frame.height, 1)
        let width = min(visibleFrame.width * 0.48, 1280)
        let height = width / displayAspectRatio
        let origin = CGPoint(
            x: visibleFrame.maxX - width - 24,
            y: visibleFrame.maxY - height - 24
        )

        return CGRect(origin: origin, size: CGSize(width: width, height: height)).integral
    }

    private func centeredOutputFrame(for screen: NSScreen) -> CGRect {
        let visibleFrame = screen.visibleFrame
        let width = min(visibleFrame.width * 0.72, 1440)
        let height = min(visibleFrame.height * 0.72, 900)
        let origin = CGPoint(
            x: visibleFrame.midX - (width / 2),
            y: visibleFrame.midY - (height / 2)
        )

        return CGRect(origin: origin, size: CGSize(width: width, height: height)).integral
    }

    private func applyPresentationBehavior(to window: NSWindow) {
        window.level = windowLevel(for: currentPresentationMode)
        window.collectionBehavior = collectionBehavior(for: currentPresentationMode)
    }

    private func windowTitle(
        delayMilliseconds: Int,
        statusLine: String,
        presentationMode: PresentationMode
    ) -> String {
        let baseTitle: String
        switch presentationMode {
        case .previewWindow:
            baseTitle = "DelayDisplay Monitor"
        case .fullscreenWindow:
            baseTitle = "DelayDisplay Output"
        }

        let modeTitle = statusLine.localizedCaseInsensitiveContains("live mode")
            ? "Live"
            : "\(delayMilliseconds) ms"

        return "\(baseTitle) - \(modeTitle)"
    }

    private func windowLevel(for presentationMode: PresentationMode) -> NSWindow.Level {
        switch presentationMode {
        case .previewWindow:
            return keepsOverlayOnTop ? .floating : .normal
        case .fullscreenWindow:
            return keepsOverlayOnTop ? .floating : .normal
        }
    }

    private func collectionBehavior(for presentationMode: PresentationMode) -> NSWindow.CollectionBehavior {
        switch presentationMode {
        case .previewWindow:
            return [.moveToActiveSpace]
        case .fullscreenWindow:
            return [.moveToActiveSpace]
        }
    }
}
