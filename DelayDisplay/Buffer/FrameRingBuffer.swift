@preconcurrency import CoreGraphics
import Foundation

actor FrameRingBuffer {
    struct Entry {
        let sourceTime: TimeInterval
        let frame: DelayedFramePayload
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

    /// Releases frames that can no longer be presented, keeping the newest frame at or
    /// before `cutoffSourceTime` because it is still on screen at that moment.
    func trim(before cutoffSourceTime: TimeInterval) {
        while entryCount > 1,
              let nextEntry = entry(atLogicalIndex: 1),
              nextEntry.sourceTime <= cutoffSourceTime {
            entries[headIndex] = nil
            headIndex = physicalIndex(forLogicalIndex: 1)
            entryCount -= 1
        }
    }

    func timingBounds() -> (oldest: TimeInterval, latest: TimeInterval)? {
        guard let oldestEntry = firstEntry,
              let latestEntry else {
            return nil
        }

        return (oldest: oldestEntry.sourceTime, latest: latestEntry.sourceTime)
    }

    func entriesForEnqueue(
        after lastQueuedSourceTime: TimeInterval?,
        targetSourceTime: TimeInterval,
        through upperBoundSourceTime: TimeInterval
    ) -> [Entry] {
        guard entryCount > 0,
              let latestEntry else {
            return []
        }

        let clampedUpperBound = min(upperBoundSourceTime, latestEntry.sourceTime)
        guard clampedUpperBound.isFinite else {
            return []
        }

        let startIndex: Int
        if let lastQueuedSourceTime {
            startIndex = firstIndex(after: lastQueuedSourceTime)
        } else if let floorIndex = floorIndex(for: targetSourceTime) {
            startIndex = floorIndex
        } else {
            startIndex = firstIndex(atOrAfter: targetSourceTime)
        }

        guard startIndex < entryCount else {
            return []
        }

        let endIndex = lastIndex(atOrBefore: clampedUpperBound)
        guard endIndex >= startIndex else {
            return []
        }

        return (startIndex...endIndex).compactMap(entry(atLogicalIndex:))
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

    private func floorIndex(for targetSourceTime: TimeInterval) -> Int? {
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

        return matchingIndex
    }

    private func firstIndex(atOrAfter targetSourceTime: TimeInterval) -> Int {
        var lowerBound = 0
        var upperBound = entryCount

        while lowerBound < upperBound {
            let middleIndex = (lowerBound + upperBound) / 2
            guard let candidateEntry = entry(atLogicalIndex: middleIndex) else {
                upperBound = middleIndex
                continue
            }

            if candidateEntry.sourceTime < targetSourceTime {
                lowerBound = middleIndex + 1
            } else {
                upperBound = middleIndex
            }
        }

        return lowerBound
    }

    private func firstIndex(after targetSourceTime: TimeInterval) -> Int {
        var lowerBound = 0
        var upperBound = entryCount

        while lowerBound < upperBound {
            let middleIndex = (lowerBound + upperBound) / 2
            guard let candidateEntry = entry(atLogicalIndex: middleIndex) else {
                upperBound = middleIndex
                continue
            }

            if candidateEntry.sourceTime <= targetSourceTime {
                lowerBound = middleIndex + 1
            } else {
                upperBound = middleIndex
            }
        }

        return lowerBound
    }

    private func lastIndex(atOrBefore targetSourceTime: TimeInterval) -> Int {
        (floorIndex(for: targetSourceTime) ?? -1)
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
