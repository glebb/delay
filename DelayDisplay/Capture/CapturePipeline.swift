@preconcurrency import CoreGraphics
import CoreMedia
import CoreVideo
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
    let frame: DelayedFramePayload?
    let isWarmingUp: Bool
    let debugInfo: CaptureDebugInfo
}

final class DelayedFramePayload: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let contentsRect: CGRect
    let imageDescription: String

    init(sampleBuffer: CMSampleBuffer, contentsRect: CGRect, imageDescription: String) {
        self.sampleBuffer = sampleBuffer
        self.contentsRect = contentsRect
        self.imageDescription = imageDescription
    }
}

enum PreparedFrameResult {
    case accepted(PreparedFrame)
    case skipped
}

struct PreparedFrame {
    let frame: DelayedFramePayload
    let sourceTime: TimeInterval
    let hostTime: TimeInterval
}

final class CaptureFramePreparer {
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

        let extent = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )
        let visibleRect = visibleImageRect(for: extent, attachments: attachments)
        let contentsRect = normalizedContentsRect(for: visibleRect, in: extent)
        let sourceTime = sourceTime(for: sampleBuffer, attachments: attachments)
        guard let displaySampleBuffer = makeDisplaySampleBuffer(from: sampleBuffer, sourceTime: sourceTime) else {
            return .skipped
        }

        return .accepted(
            PreparedFrame(
                frame: DelayedFramePayload(
                    sampleBuffer: displaySampleBuffer,
                    contentsRect: contentsRect,
                    imageDescription: "\(Int(visibleRect.width.rounded()))x\(Int(visibleRect.height.rounded()))"
                ),
                sourceTime: sourceTime,
                hostTime: hostTime(for: attachments)
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

    private func normalizedContentsRect(for visibleRect: CGRect, in extent: CGRect) -> CGRect {
        guard extent.width > 0,
              extent.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let normalizedX = visibleRect.minX / extent.width
        let normalizedY = visibleRect.minY / extent.height
        let normalizedWidth = visibleRect.width / extent.width
        let normalizedHeight = visibleRect.height / extent.height

        return CGRect(
            x: normalizedX,
            y: normalizedY,
            width: normalizedWidth,
            height: normalizedHeight
        )
    }

    private func sourceTime(
        for sampleBuffer: CMSampleBuffer,
        attachments: [SCStreamFrameInfo: Any]?
    ) -> TimeInterval {
        let displayTime = hostTime(for: attachments)
        if displayTime > 0 {
            return displayTime
        }

        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTimeStamp.isValid,
              !presentationTimeStamp.isIndefinite,
              !presentationTimeStamp.isPositiveInfinity,
              !presentationTimeStamp.isNegativeInfinity else {
            return CACurrentMediaTime()
        }

        let seconds = presentationTimeStamp.seconds
        return seconds.isFinite ? seconds : CACurrentMediaTime()
    }

    private func hostTime(for attachments: [SCStreamFrameInfo: Any]?) -> TimeInterval {
        guard let hostTimeValue = attachments?[.displayTime] as? UInt64,
              hostTimeValue > 0 else {
            return CACurrentMediaTime()
        }

        let hostClockFrequency = CVGetHostClockFrequency()
        guard hostClockFrequency > 0 else {
            return CACurrentMediaTime()
        }

        return Double(hostTimeValue) / hostClockFrequency
    }

    private func makeDisplaySampleBuffer(
        from sampleBuffer: CMSampleBuffer,
        sourceTime: TimeInterval
    ) -> CMSampleBuffer? {
        guard let sourceImageBuffer = sampleBuffer.imageBuffer,
              let copiedPixelBuffer = makeIndependentPixelBuffer(from: sourceImageBuffer) else {
            return nil
        }

        let presentationTimeStamp = CMTime(seconds: sourceTime, preferredTimescale: 600)
        let timingInfo = CMSampleTimingInfo(
            duration: frameDuration(for: sampleBuffer),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )

        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: copiedPixelBuffer,
            formatDescriptionOut: &formatDescription
        )

        guard formatStatus == noErr,
              let formatDescription else {
            return nil
        }

        var copiedSampleBuffer: CMSampleBuffer?
        var sampleTimingInfo = timingInfo
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: copiedPixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &sampleTimingInfo,
            sampleBufferOut: &copiedSampleBuffer
        )

        guard status == noErr,
              let copiedSampleBuffer else {
            return nil
        }

        markDisplayImmediately(copiedSampleBuffer)
        return copiedSampleBuffer
    }

    private func makeIndependentPixelBuffer(from imageBuffer: CVImageBuffer) -> CVPixelBuffer? {
        let sourcePixelBuffer = imageBuffer as CVPixelBuffer
        let width = CVPixelBufferGetWidth(sourcePixelBuffer)
        let height = CVPixelBufferGetHeight(sourcePixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(sourcePixelBuffer)
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        var destinationPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &destinationPixelBuffer
        )

        guard status == kCVReturnSuccess,
              let destinationPixelBuffer else {
            return nil
        }

        CVBufferPropagateAttachments(sourcePixelBuffer, destinationPixelBuffer)
        CVPixelBufferLockBaseAddress(sourcePixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(destinationPixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destinationPixelBuffer, [])
            CVPixelBufferUnlockBaseAddress(sourcePixelBuffer, .readOnly)
        }

        let planeCount = CVPixelBufferGetPlaneCount(sourcePixelBuffer)
        if planeCount == 0 {
            guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(sourcePixelBuffer),
                  let destinationBaseAddress = CVPixelBufferGetBaseAddress(destinationPixelBuffer) else {
                return nil
            }

            let bytesPerRow = min(
                CVPixelBufferGetBytesPerRow(sourcePixelBuffer),
                CVPixelBufferGetBytesPerRow(destinationPixelBuffer)
            )
            let rowCount = min(
                CVPixelBufferGetHeight(sourcePixelBuffer),
                CVPixelBufferGetHeight(destinationPixelBuffer)
            )

            for rowIndex in 0..<rowCount {
                let sourceRow = sourceBaseAddress.advanced(by: rowIndex * CVPixelBufferGetBytesPerRow(sourcePixelBuffer))
                let destinationRow = destinationBaseAddress.advanced(by: rowIndex * CVPixelBufferGetBytesPerRow(destinationPixelBuffer))
                memcpy(destinationRow, sourceRow, bytesPerRow)
            }

            return destinationPixelBuffer
        }

        for planeIndex in 0..<planeCount {
            guard let sourcePlaneBaseAddress = CVPixelBufferGetBaseAddressOfPlane(sourcePixelBuffer, planeIndex),
                  let destinationPlaneBaseAddress = CVPixelBufferGetBaseAddressOfPlane(destinationPixelBuffer, planeIndex) else {
                return nil
            }

            let bytesPerRow = min(
                CVPixelBufferGetBytesPerRowOfPlane(sourcePixelBuffer, planeIndex),
                CVPixelBufferGetBytesPerRowOfPlane(destinationPixelBuffer, planeIndex)
            )
            let rowCount = min(
                CVPixelBufferGetHeightOfPlane(sourcePixelBuffer, planeIndex),
                CVPixelBufferGetHeightOfPlane(destinationPixelBuffer, planeIndex)
            )

            for rowIndex in 0..<rowCount {
                let sourceRow = sourcePlaneBaseAddress.advanced(by: rowIndex * CVPixelBufferGetBytesPerRowOfPlane(sourcePixelBuffer, planeIndex))
                let destinationRow = destinationPlaneBaseAddress.advanced(by: rowIndex * CVPixelBufferGetBytesPerRowOfPlane(destinationPixelBuffer, planeIndex))
                memcpy(destinationRow, sourceRow, bytesPerRow)
            }
        }

        return destinationPixelBuffer
    }

    private func frameDuration(for sampleBuffer: CMSampleBuffer) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        guard duration.isValid,
              !duration.isIndefinite,
              !duration.isPositiveInfinity,
              !duration.isNegativeInfinity,
              duration.seconds > 0 else {
            return .invalid
        }

        return duration
    }

    private func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else {
            return
        }

        let attachmentDictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0),
            to: CFMutableDictionary.self
        )
        CFDictionarySetValue(
            attachmentDictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
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
    private var lastPresentedFrame: DelayedFramePayload?
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
        lastPresentedFrame = nil
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
        let sourceTime = preparedFrame.sourceTime
        latestSourceTime = sourceTime
        latestHostTime = preparedFrame.hostTime
        latestImageDescription = preparedFrame.frame.imageDescription
        recordEvent(preparedFrame.hostTime, in: &recentAcceptedHostTimes)
        _ = await frameBuffer.append(preparedFrame.frame, sourceTime: sourceTime)
    }

    func presentation(atHostTime hostTime: TimeInterval) async -> CapturePresentation {
        let bufferedFrames = await frameBuffer.bufferedFrameCount()
        let bufferedDurationMilliseconds = await frameBuffer.bufferedDurationMilliseconds()
        let estimatedSourceNow = estimatedSourceTime(atHostTime: hostTime)

        guard let estimatedSourceNow else {
            return CapturePresentation(
                frame: lastPresentedFrame,
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

        var frameToDisplay = lastPresentedFrame
        var isWarmingUp = false

        switch lookupResult {
        case .warmingUp:
            isWarmingUp = true
            isUnderrunning = false
        case .ready(let entry):
            frameToDisplay = entry.frame
            isUnderrunning = false

            if entry.sourceTime != lastPresentedSourceTime {
                emittedFrames += 1
                lastPresentedSourceTime = entry.sourceTime
                lastPresentedFrame = entry.frame
                recordEvent(hostTime, in: &recentPresentedHostTimes)
            }
        case .underrun:
            if !isUnderrunning && lastPresentedFrame != nil {
                underrunCount += 1
            }

            isUnderrunning = true
        }

        let displayedSourceTime = lastPresentedSourceTime
        let effectiveDelayMilliseconds = displayedSourceTime.map {
            max(Int(((estimatedSourceNow - $0) * 1_000).rounded()), 0)
        }

        return CapturePresentation(
            frame: frameToDisplay,
            isWarmingUp: isWarmingUp,
            debugInfo: makeDebugInfo(
                bufferedFrames: bufferedFrames,
                bufferedDurationMilliseconds: bufferedDurationMilliseconds,
                effectiveDelayMilliseconds: effectiveDelayMilliseconds,
                hostTime: hostTime
            )
        )
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