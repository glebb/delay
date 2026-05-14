import CoreGraphics
import Foundation

struct PermissionsService {
    func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
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
