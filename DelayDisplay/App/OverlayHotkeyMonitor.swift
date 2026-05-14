import AppKit
import CoreGraphics

@MainActor
final class OverlayHotkeyMonitor {
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private let keyActivityHandler: () -> Void
    private let shouldHandleKeyActivity: () -> Bool

    init(
        onKeyActivity: @escaping () -> Void,
        shouldHandleKeyActivity: @escaping () -> Bool
    ) {
        self.keyActivityHandler = onKeyActivity
        self.shouldHandleKeyActivity = shouldHandleKeyActivity
    }

    func start() {
        guard localMonitor == nil, eventTap == nil else {
            return
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            if self.shouldHandleKeyActivity() {
                self.keyActivityHandler()
            }

            return event
        }

        installEventTapIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    func refresh() {
        installEventTapIfNeeded(forceReinstall: true)
    }

    func stop() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    @objc
    private func handleApplicationDidBecomeActive() {
        installEventTapIfNeeded(forceReinstall: true)
    }

    private func installEventTapIfNeeded(forceReinstall: Bool = false) {
        if forceReinstall {
            if let eventTapRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
                self.eventTapRunLoopSource = nil
            }

            if let eventTap {
                CFMachPortInvalidate(eventTap)
                self.eventTap = nil
            }
        } else if eventTap != nil {
            return
        }

        let keyDownMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: keyDownMask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            return
        }

        self.eventTap = eventTap
        self.eventTapRunLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func handleExternalKeyDown(keyCode: Int64) {
        if shouldHandleKeyActivity() {
            keyActivityHandler()
        }
    }

    private func handleEventTapDisabled() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    nonisolated private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let monitor = Unmanaged<OverlayHotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor in
                monitor.handleEventTapDisabled()
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        Task { @MainActor in
            monitor.handleExternalKeyDown(keyCode: keyCode)
        }

        return Unmanaged.passUnretained(event)
    }
}