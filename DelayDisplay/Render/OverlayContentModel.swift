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
        underrunCount: 0,
        bufferedFrames: 0,
        bufferedDurationMilliseconds: 0,
        effectiveDelayMilliseconds: nil,
        captureFramesPerSecond: 0,
        presentationFramesPerSecond: 0,
        qualityPresetDescription: "Balanced",
        latestImageDescription: "n/a"
    )

    func update(delayMilliseconds: Int, statusLine: String) {
        if self.delayMilliseconds != delayMilliseconds {
            self.delayMilliseconds = delayMilliseconds
        }

        if self.statusLine != statusLine {
            self.statusLine = statusLine
        }
    }

    func updatePresentation(showsDebugHUD: Bool) {
        if self.showsDebugHUD != showsDebugHUD {
            self.showsDebugHUD = showsDebugHUD
        }
    }

    func updateFrame(_ frame: CGImage?, isWarmingUp: Bool, debugInfo: CaptureDebugInfo) {
        self.debugInfo = debugInfo
        self.isWarmingUp = isWarmingUp

        guard let frame else {
            return
        }

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
            underrunCount: 0,
            bufferedFrames: 0,
            bufferedDurationMilliseconds: 0,
            effectiveDelayMilliseconds: nil,
            captureFramesPerSecond: 0,
            presentationFramesPerSecond: 0,
            qualityPresetDescription: "Balanced",
            latestImageDescription: "n/a"
        )
    }
}