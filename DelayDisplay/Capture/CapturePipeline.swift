@preconcurrency import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import QuartzCore
import ScreenCaptureKit

struct CaptureDebugInfo: Sendable {
    let receivedFrames: Int
    let acceptedFrames: Int
    let emittedFrames: Int
    let skippedFrames: Int
    let underrunCount: Int
    let bufferedFrames: Int
    let bufferedDurationMilliseconds: Int
    let effectiveDelayMilliseconds: Int?
    let captureFramesPerSecond: Int
    let presentationFramesPerSecond: Int
    let qualityPresetDescription: String
    let latestImageDescription: String
}

struct CapturePresentation: Sendable {
    let image: CGImage?
    let isWarmingUp: Bool
    let debugInfo: CaptureDebugInfo
}

enum PreparedFrameResult {
    case accepted(PreparedFrame)
    case skipped
}

struct PreparedFrame {
    let image: CGImage
    let sourceTime: TimeInterval?
    let hostTime: TimeInterval
    let imageDescription: String
}

final class CaptureFramePreparer {
    private let imageContext = CIContext()

    func prepare(sampleBuffer: CMSampleBuffer) -> PreparedFrameResult {
        guard sampleBuffer.isValid,
              let imageBuffer = sampleBuffer.imageBuffer else {
            return .skipped
        }

        let attachments = sampleAttachments(for: sampleBuffer)
        if let attachments,
           !isUsableFrame(attachments) {
            return .skipped
        }

        let hostTime = CACurrentMediaTime()
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let visibleRect = visibleImageRect(for: ciImage.extent, attachments: attachments)

        guard let cgImage = imageContext.createCGImage(ciImage, from: visibleRect) else {
            return .skipped
        }

        return .accepted(
            PreparedFrame(
                image: cgImage,
                sourceTime: sourceTime(for: sampleBuffer),
                hostTime: hostTime,
                imageDescription: "\(cgImage.width)x\(cgImage.height)"
            )
        )
    }

    private func sampleAttachments(for sampleBuffer: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]] else {
            return nil
        }

        return attachmentsArray.first
    }

    private func isUsableFrame(_ attachments: [SCStreamFrameInfo: Any]) -> Bool {
        guard let statusRawValue = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue) else {
            return true
        }

        return status == .complete
    }

    private func visibleImageRect(
        for extent: CGRect,
        attachments: [SCStreamFrameInfo: Any]?
    ) -> CGRect {
        guard let attachments,
              let contentRectValue = attachments[.contentRect] else {
            return extent
        }

        let pointRect: CGRect?
        if let rect = contentRectValue as? CGRect {
            pointRect = rect
        } else if let dictionary = contentRectValue as? NSDictionary {
            pointRect = CGRect(dictionaryRepresentation: dictionary)
        } else {
            pointRect = nil
        }

        guard let pointRect,
              !pointRect.isEmpty else {
            return extent
        }

        let scale = (attachments[.scaleFactor] as? CGFloat)
            ?? (attachments[.contentScale] as? CGFloat)
            ?? 1

        let scaledRect = CGRect(
            x: pointRect.origin.x * scale,
            y: pointRect.origin.y * scale,
            width: pointRect.width * scale,
            height: pointRect.height * scale
        ).integral

        let croppedRect = extent.intersection(scaledRect)
        return croppedRect.isNull || croppedRect.isEmpty ? extent : croppedRect
    }

    private func sourceTime(for sampleBuffer: CMSampleBuffer) -> TimeInterval? {
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTimeStamp.isValid,
              !presentationTimeStamp.isIndefinite,
              !presentationTimeStamp.isPositiveInfinity,
              !presentationTimeStamp.isNegativeInfinity else {
            return nil
        }

        let seconds = presentationTimeStamp.seconds
        return seconds.isFinite ? seconds : nil
    }
}

actor CapturePipeline {
    private let frameBuffer: FrameRingBuffer
    private let qualityPreset: CaptureQualityPreset
    private var delayMilliseconds: Int
    private var receivedFrames = 0
    private var acceptedFrames = 0
    private var emittedFrames = 0
    private var skippedFrames = 0
    private var underrunCount = 0
    private var latestSourceTime: TimeInterval?
    private var latestHostTime: TimeInterval?
    private var latestImageDescription = "n/a"
    private var lastPresentedSourceTime: TimeInterval?
    private var lastPresentedImage: CGImage?
    private var isUnderrunning = false
    private var recentAcceptedHostTimes: [TimeInterval] = []
    private var recentPresentedHostTimes: [TimeInterval] = []

    init(
        delayMilliseconds: Int,
        qualityPreset: CaptureQualityPreset,
        frameBuffer: FrameRingBuffer = FrameRingBuffer()
    ) {
        self.delayMilliseconds = delayMilliseconds
        self.qualityPreset = qualityPreset
        self.frameBuffer = frameBuffer
    }

    func updateDelay(_ delayMilliseconds: Int) {
        self.delayMilliseconds = delayMilliseconds
    }

    func reset() async {
        await frameBuffer.clear()
        receivedFrames = 0
        acceptedFrames = 0
        emittedFrames = 0
        skippedFrames = 0
        underrunCount = 0
        latestSourceTime = nil
        latestHostTime = nil
        latestImageDescription = "n/a"
        lastPresentedSourceTime = nil
        lastPresentedImage = nil
        isUnderrunning = false
        recentAcceptedHostTimes.removeAll(keepingCapacity: false)
        recentPresentedHostTimes.removeAll(keepingCapacity: false)
    }

    func ingest(_ preparedFrameResult: PreparedFrameResult) async {
        receivedFrames += 1

        guard case .accepted(let preparedFrame) = preparedFrameResult else {
            skippedFrames += 1
            return
        }

        acceptedFrames += 1
        let sourceTime = preparedFrame.sourceTime ?? fallbackSourceTime(forHostTime: preparedFrame.hostTime)
        latestSourceTime = sourceTime
        latestHostTime = preparedFrame.hostTime
        latestImageDescription = preparedFrame.imageDescription
        recordEvent(preparedFrame.hostTime, in: &recentAcceptedHostTimes)
        _ = await frameBuffer.append(preparedFrame.image, sourceTime: sourceTime)
    }

    func presentation(atHostTime hostTime: TimeInterval) async -> CapturePresentation {
        let bufferedFrames = await frameBuffer.bufferedFrameCount()
        let bufferedDurationMilliseconds = await frameBuffer.bufferedDurationMilliseconds()
        let estimatedSourceNow = estimatedSourceTime(atHostTime: hostTime)

        guard let estimatedSourceNow else {
            return CapturePresentation(
                image: lastPresentedImage,
                isWarmingUp: true,
                debugInfo: makeDebugInfo(
                    bufferedFrames: bufferedFrames,
                    bufferedDurationMilliseconds: bufferedDurationMilliseconds,
                    effectiveDelayMilliseconds: nil,
                    hostTime: hostTime
                )
            )
        }

        let unclampedTargetSourceTime = estimatedSourceNow - (Double(delayMilliseconds) / 1_000.0)
        let targetSourceTime: TimeInterval
        if delayMilliseconds <= 0,
           let latestSourceTime {
            targetSourceTime = min(unclampedTargetSourceTime, latestSourceTime)
        } else {
            targetSourceTime = unclampedTargetSourceTime
        }

        let lookupResult = await frameBuffer.entry(forTargetSourceTime: targetSourceTime)

        var imageToDisplay = lastPresentedImage
        var isWarmingUp = false

        switch lookupResult {
        case .warmingUp:
            isWarmingUp = true
            isUnderrunning = false
        case .ready(let entry):
            imageToDisplay = entry.image
            isUnderrunning = false

            if entry.sourceTime != lastPresentedSourceTime {
                emittedFrames += 1
                lastPresentedSourceTime = entry.sourceTime
                lastPresentedImage = entry.image
                recordEvent(hostTime, in: &recentPresentedHostTimes)
            }
        case .underrun:
            if !isUnderrunning && lastPresentedImage != nil {
                underrunCount += 1
            }

            isUnderrunning = true
        }

        let displayedSourceTime = lastPresentedSourceTime
        let effectiveDelayMilliseconds = displayedSourceTime.map {
            max(Int(((estimatedSourceNow - $0) * 1_000).rounded()), 0)
        }

        return CapturePresentation(
            image: imageToDisplay,
            isWarmingUp: isWarmingUp,
            debugInfo: makeDebugInfo(
                bufferedFrames: bufferedFrames,
                bufferedDurationMilliseconds: bufferedDurationMilliseconds,
                effectiveDelayMilliseconds: effectiveDelayMilliseconds,
                hostTime: hostTime
            )
        )
    }

    private func fallbackSourceTime(forHostTime hostTime: TimeInterval) -> TimeInterval {
        guard let latestSourceTime,
              let latestHostTime else {
            return hostTime
        }

        let hostDelta = max(hostTime - latestHostTime, 1.0 / 60.0)
        return latestSourceTime + hostDelta
    }

    private func estimatedSourceTime(atHostTime hostTime: TimeInterval) -> TimeInterval? {
        guard let latestSourceTime,
              let latestHostTime else {
            return nil
        }

        return latestSourceTime + max(hostTime - latestHostTime, 0)
    }

    private func makeDebugInfo(
        bufferedFrames: Int,
        bufferedDurationMilliseconds: Int,
        effectiveDelayMilliseconds: Int?,
        hostTime: TimeInterval
    ) -> CaptureDebugInfo {
        CaptureDebugInfo(
            receivedFrames: receivedFrames,
            acceptedFrames: acceptedFrames,
            emittedFrames: emittedFrames,
            skippedFrames: skippedFrames,
            underrunCount: underrunCount,
            bufferedFrames: bufferedFrames,
            bufferedDurationMilliseconds: bufferedDurationMilliseconds,
            effectiveDelayMilliseconds: effectiveDelayMilliseconds,
            captureFramesPerSecond: framesPerSecond(for: recentAcceptedHostTimes, now: hostTime),
            presentationFramesPerSecond: framesPerSecond(for: recentPresentedHostTimes, now: hostTime),
            qualityPresetDescription: qualityPreset.title,
            latestImageDescription: latestImageDescription
        )
    }

    private func recordEvent(_ hostTime: TimeInterval, in eventTimes: inout [TimeInterval]) {
        eventTimes.append(hostTime)
        let oldestAllowedTime = hostTime - 1.0
        eventTimes.removeAll(where: { $0 < oldestAllowedTime })
    }

    private func framesPerSecond(for eventTimes: [TimeInterval], now: TimeInterval) -> Int {
        let recentEventTimes = eventTimes.filter { $0 >= now - 1.0 }
        guard let firstEventTime = recentEventTimes.first,
              let lastEventTime = recentEventTimes.last,
              recentEventTimes.count > 1 else {
            return recentEventTimes.isEmpty ? 0 : recentEventTimes.count
        }

        let elapsed = max(lastEventTime - firstEventTime, 0.001)
        return max(Int((Double(recentEventTimes.count - 1) / elapsed).rounded()), 0)
    }
}