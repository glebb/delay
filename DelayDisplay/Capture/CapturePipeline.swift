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
    let bufferedFrames: Int
    let bufferedDurationMilliseconds: Int
    let effectiveDelayMilliseconds: Int?
    let latestImageDescription: String
}

typealias DelayedFrameConsumer = @Sendable (_ image: CGImage?, _ isWarmingUp: Bool, _ debugInfo: CaptureDebugInfo) async -> Void

actor CapturePipeline {
    private let frameBuffer: FrameRingBuffer
    private let imageContext: CIContext
    private let frameConsumer: DelayedFrameConsumer
    private var delayMilliseconds: Int
    private var receivedFrames = 0
    private var acceptedFrames = 0
    private var emittedFrames = 0
    private var skippedFrames = 0

    init(
        delayMilliseconds: Int,
        frameBuffer: FrameRingBuffer = FrameRingBuffer(),
        imageContext: CIContext = CIContext(),
        frameConsumer: @escaping DelayedFrameConsumer
    ) {
        self.delayMilliseconds = delayMilliseconds
        self.frameBuffer = frameBuffer
        self.imageContext = imageContext
        self.frameConsumer = frameConsumer
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
    }

    func process(sampleBuffer: CMSampleBuffer) async {
        receivedFrames += 1

        guard sampleBuffer.isValid,
              let imageBuffer = sampleBuffer.imageBuffer else {
            skippedFrames += 1
            return
        }

        let attachments = sampleAttachments(for: sampleBuffer)
        if let attachments,
           !isUsableFrame(attachments) {
            skippedFrames += 1
            return
        }

        let captureTime = CACurrentMediaTime()
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let visibleRect = visibleImageRect(for: ciImage.extent, attachments: attachments)

        guard let cgImage = imageContext.createCGImage(ciImage, from: visibleRect) else {
            skippedFrames += 1
            return
        }

        acceptedFrames += 1
        let bufferedFrames = await frameBuffer.append(cgImage, captureTime: captureTime)
        let delayedEntry = await frameBuffer.entry(
            forDelayMilliseconds: delayMilliseconds,
            latestCaptureTime: captureTime
        )
        let delayedImage = delayedEntry?.image
        let imageToDisplay = delayedImage ?? cgImage
        let bufferedDurationMilliseconds = await frameBuffer.bufferedDurationMilliseconds(latestCaptureTime: captureTime)

        if delayedImage != nil {
            emittedFrames += 1
        }

        let debugInfo = CaptureDebugInfo(
            receivedFrames: receivedFrames,
            acceptedFrames: acceptedFrames,
            emittedFrames: emittedFrames,
            skippedFrames: skippedFrames,
            bufferedFrames: bufferedFrames,
            bufferedDurationMilliseconds: bufferedDurationMilliseconds,
            effectiveDelayMilliseconds: delayedEntry.map { Int(((captureTime - $0.captureTime) * 1_000).rounded()) },
            latestImageDescription: "\(cgImage.width)x\(cgImage.height)"
        )

        await frameConsumer(imageToDisplay, delayedImage == nil, debugInfo)
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
}