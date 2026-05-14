import Combine
import CoreGraphics
import QuartzCore
import Foundation

@MainActor
final class OverlayContentModel: ObservableObject {
    let framePublisher = PassthroughSubject<DelayedFramePayload?, Never>()

    @Published private(set) var hasImage = false
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
    private var lastDebugInfoUpdateTime: TimeInterval = 0

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

    func updateFrame(_ frame: DelayedFramePayload?, isWarmingUp: Bool, debugInfo: CaptureDebugInfo) {
        let shouldShowPlaceholder = frame == nil && !hasImage
        if self.isWarmingUp != shouldShowPlaceholder && (shouldShowPlaceholder || !isWarmingUp) {
            self.isWarmingUp = shouldShowPlaceholder
        }

        if let frame {
            if !hasImage {
                hasImage = true
            }

            framePublisher.send(frame)
        }

        let now = CACurrentMediaTime()
        if now - lastDebugInfoUpdateTime >= 0.125 {
            self.debugInfo = debugInfo
            lastDebugInfoUpdateTime = now
        }
    }

    func reset() {
        framePublisher.send(nil)
        hasImage = false
        isWarmingUp = false
        statusLine = "Idle"
        lastDebugInfoUpdateTime = 0
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