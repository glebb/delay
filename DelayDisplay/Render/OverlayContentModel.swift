import CoreGraphics
import Foundation

@MainActor
final class OverlayContentModel: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var delayMilliseconds = 0
    @Published private(set) var statusLine = "Idle"
    @Published private(set) var isWarmingUp = false
    @Published private(set) var showsDebugHUD = true
    @Published private(set) var debugInfo = CaptureDebugInfo(
        receivedFrames: 0,
        acceptedFrames: 0,
        emittedFrames: 0,
        skippedFrames: 0,
        bufferedFrames: 0,
        bufferedDurationMilliseconds: 0,
        effectiveDelayMilliseconds: nil,
        latestImageDescription: "n/a"
    )

    func update(delayMilliseconds: Int, statusLine: String) {
        self.delayMilliseconds = delayMilliseconds
        self.statusLine = statusLine
    }

    func updatePresentation(showsDebugHUD: Bool) {
        self.showsDebugHUD = showsDebugHUD
    }

    func updateFrame(_ frame: CGImage?, isWarmingUp: Bool, debugInfo: CaptureDebugInfo) {
        self.debugInfo = debugInfo

        guard let frame else {
            self.isWarmingUp = image == nil && isWarmingUp
            return
        }

        self.isWarmingUp = false
        image = frame
    }

    func reset() {
        image = nil
        isWarmingUp = false
        statusLine = "Idle"
        debugInfo = CaptureDebugInfo(
            receivedFrames: 0,
            acceptedFrames: 0,
            emittedFrames: 0,
            skippedFrames: 0,
            bufferedFrames: 0,
            bufferedDurationMilliseconds: 0,
            effectiveDelayMilliseconds: nil,
            latestImageDescription: "n/a"
        )
    }
}