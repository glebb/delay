import Combine
import CoreGraphics
import QuartzCore
import Foundation

@MainActor
final class OverlayContentModel: ObservableObject {
    enum PlaybackCommand {
        case clear
        case configure(delayMilliseconds: Int, shouldFlush: Bool)
        case enqueue(DelayedFramePayload)
    }

    let playbackPublisher = PassthroughSubject<PlaybackCommand, Never>()

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
    private var lastConfiguredDelayMilliseconds: Int?

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

    func updatePlayback(
        framesToEnqueue: [DelayedFramePayload],
        delayMilliseconds: Int,
        shouldResetRenderer: Bool,
        isWarmingUp: Bool,
        debugInfo: CaptureDebugInfo
    ) {
        let shouldShowPlaceholder = framesToEnqueue.isEmpty && !hasImage
        if self.isWarmingUp != shouldShowPlaceholder && (shouldShowPlaceholder || !isWarmingUp) {
            self.isWarmingUp = shouldShowPlaceholder
        }

        if shouldResetRenderer || lastConfiguredDelayMilliseconds != delayMilliseconds {
            playbackPublisher.send(.configure(delayMilliseconds: delayMilliseconds, shouldFlush: true))
            lastConfiguredDelayMilliseconds = delayMilliseconds
        }

        for frame in framesToEnqueue {
            if !hasImage {
                hasImage = true
            }

            playbackPublisher.send(.enqueue(frame))
        }

        let now = CACurrentMediaTime()
        if now - lastDebugInfoUpdateTime >= 0.125 {
            self.debugInfo = debugInfo
            lastDebugInfoUpdateTime = now
        }
    }

    func reset() {
        playbackPublisher.send(.clear)
        hasImage = false
        isWarmingUp = false
        statusLine = "Idle"
        lastDebugInfoUpdateTime = 0
        lastConfiguredDelayMilliseconds = nil
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