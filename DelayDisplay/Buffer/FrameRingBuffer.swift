@preconcurrency import CoreGraphics
import Foundation

actor FrameRingBuffer {
    struct Entry {
        let sourceTime: TimeInterval
        let image: CGImage
    }

    enum LookupResult {
        case warmingUp
        case ready(Entry)
        case underrun
    }

    private let maximumEntryCount: Int
    private var entries: [Entry] = []

    init(maximumDelayMilliseconds: Int = 10_000, assumedFramesPerSecond: Int32 = 60) {
        let frameBudget = Int((Double(maximumDelayMilliseconds) / 1_000.0) * Double(assumedFramesPerSecond))
        self.maximumEntryCount = max(frameBudget, 1)
    }

    func append(_ image: CGImage, sourceTime: TimeInterval) -> Int {
        let storedSourceTime: TimeInterval
        if let latestSourceTime = entries.last?.sourceTime,
           sourceTime <= latestSourceTime {
            storedSourceTime = latestSourceTime + 0.000_001
        } else {
            storedSourceTime = sourceTime
        }

        entries.append(Entry(sourceTime: storedSourceTime, image: image))

        if entries.count > maximumEntryCount {
            entries.removeFirst(entries.count - maximumEntryCount)
        }

        return entries.count
    }

    func entry(forTargetSourceTime targetSourceTime: TimeInterval) -> LookupResult {
        guard let oldestEntry = entries.first,
              let latestEntry = entries.last else {
            return .warmingUp
        }

        if targetSourceTime < oldestEntry.sourceTime {
            return .warmingUp
        }

        if targetSourceTime > latestEntry.sourceTime {
            return .underrun
        }

        guard let entry = entries.last(where: { $0.sourceTime <= targetSourceTime }) else {
            return .warmingUp
        }

        return .ready(entry)
    }

    func bufferedDurationMilliseconds() -> Int {
        guard let oldestSourceTime = entries.first?.sourceTime,
              let latestSourceTime = entries.last?.sourceTime else {
            return 0
        }

        return max(Int(((latestSourceTime - oldestSourceTime) * 1_000).rounded()), 0)
    }

    func bufferedFrameCount() -> Int {
        entries.count
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }
}
