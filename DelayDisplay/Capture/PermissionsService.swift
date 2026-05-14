import ApplicationServices
import CoreGraphics
import Foundation

struct PermissionsService {
    func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermissionIfNeeded(prompt: Bool) -> Bool {
        if hasAccessibilityPermission() {
            return true
        }

        guard prompt else {
            return false
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func requestScreenRecordingPermissionIfNeeded() -> Bool {
        if hasScreenRecordingPermission() {
            return true
        }

        DispatchQueue.global(qos: .userInitiated).async {
            _ = CGRequestScreenCaptureAccess()
        }

        return false
    }
}
