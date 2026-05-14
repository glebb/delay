@preconcurrency import CoreGraphics
import Foundation

actor FrameRingBuffer {
    struct Entry {
        let captureTime: TimeInterval
        let image: CGImage
    }

    private let maximumEntryCount: Int
    private var entries: [Entry] = []

    init(maximumDelayMilliseconds: Int = 10_000, assumedFramesPerSecond: Int32 = 60) {
        let frameBudget = Int((Double(maximumDelayMilliseconds) / 1_000.0) * Double(assumedFramesPerSecond))
        self.maximumEntryCount = max(frameBudget, 1)
    }

    func append(_ image: CGImage, captureTime: TimeInterval) -> Int {
        entries.append(Entry(captureTime: captureTime, image: image))

        if entries.count > maximumEntryCount {
            entries.removeFirst(entries.count - maximumEntryCount)
        }

        return entries.count
    }

    func entry(forDelayMilliseconds delayMilliseconds: Int, latestCaptureTime: TimeInterval) -> Entry? {
        guard !entries.isEmpty else {
            return nil
        }

        let targetTime = latestCaptureTime - (Double(delayMilliseconds) / 1_000.0)
        guard let oldestCaptureTime = entries.first?.captureTime,
              targetTime >= oldestCaptureTime else {
            return nil
        }

        return entries.last { $0.captureTime <= targetTime }
    }

    func bufferedDurationMilliseconds(latestCaptureTime: TimeInterval) -> Int {
        guard let oldestCaptureTime = entries.first?.captureTime else {
            return 0
        }

        return max(Int(((latestCaptureTime - oldestCaptureTime) * 1_000).rounded()), 0)
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}
