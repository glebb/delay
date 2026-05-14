@preconcurrency import CoreGraphics
import Foundation

actor FrameRingBuffer {
    struct Entry {
        let sourceTime: TimeInterval
        let frame: DelayedFramePayload
    }

    enum LookupResult {
        case warmingUp
        case ready(Entry)
        case underrun
    }

    private let maximumEntryCount: Int
    private var entries: [Entry?]
    private var headIndex = 0
    private var entryCount = 0

    init(maximumDelayMilliseconds: Int = 10_000, assumedFramesPerSecond: Int32 = 60) {
        let frameBudget = Int((Double(maximumDelayMilliseconds) / 1_000.0) * Double(assumedFramesPerSecond))
        self.maximumEntryCount = max(frameBudget, 1)
        self.entries = Array(repeating: nil, count: self.maximumEntryCount)
    }

    func append(_ frame: DelayedFramePayload, sourceTime: TimeInterval) -> Int {
        let storedSourceTime: TimeInterval
        if let latestSourceTime = latestEntry?.sourceTime,
           sourceTime <= latestSourceTime {
            storedSourceTime = latestSourceTime + 0.000_001
        } else {
            storedSourceTime = sourceTime
        }

        let entry = Entry(sourceTime: storedSourceTime, frame: frame)

        if entryCount < maximumEntryCount {
            entries[physicalIndex(forLogicalIndex: entryCount)] = entry
            entryCount += 1
        } else {
            entries[headIndex] = entry
            headIndex = physicalIndex(forLogicalIndex: 1)
        }

        return entryCount
    }

    func entry(forTargetSourceTime targetSourceTime: TimeInterval) -> LookupResult {
        guard let oldestEntry = firstEntry,
              let latestEntry else {
            return .warmingUp
        }

        if targetSourceTime < oldestEntry.sourceTime {
            return .warmingUp
        }

        if targetSourceTime > latestEntry.sourceTime {
            return .underrun
        }

        var lowerBound = 0
        var upperBound = entryCount - 1
        var matchingIndex: Int?

        while lowerBound <= upperBound {
            let middleIndex = (lowerBound + upperBound) / 2
            guard let candidateEntry = entry(atLogicalIndex: middleIndex) else {
                break
            }

            if candidateEntry.sourceTime <= targetSourceTime {
                matchingIndex = middleIndex
                lowerBound = middleIndex + 1
            } else {
                upperBound = middleIndex - 1
            }
        }

        guard let previousIndex = matchingIndex,
              let previousEntry = entry(atLogicalIndex: previousIndex) else {
            return .warmingUp
        }

        return .ready(previousEntry)
    }

    func bufferedDurationMilliseconds() -> Int {
        guard let oldestSourceTime = firstEntry?.sourceTime,
              let latestSourceTime = latestEntry?.sourceTime else {
            return 0
        }

        return max(Int(((latestSourceTime - oldestSourceTime) * 1_000).rounded()), 0)
    }

    func bufferedFrameCount() -> Int {
        entryCount
    }

    func clear() {
        entries = Array(repeating: nil, count: maximumEntryCount)
        headIndex = 0
        entryCount = 0
    }

    private var firstEntry: Entry? {
        entry(atLogicalIndex: 0)
    }

    private var latestEntry: Entry? {
        entry(atLogicalIndex: entryCount - 1)
    }

    private func entry(atLogicalIndex logicalIndex: Int) -> Entry? {
        guard logicalIndex >= 0,
              logicalIndex < entryCount else {
            return nil
        }

        return entries[physicalIndex(forLogicalIndex: logicalIndex)]
    }

    private func physicalIndex(forLogicalIndex logicalIndex: Int) -> Int {
        (headIndex + logicalIndex) % maximumEntryCount
    }
}
