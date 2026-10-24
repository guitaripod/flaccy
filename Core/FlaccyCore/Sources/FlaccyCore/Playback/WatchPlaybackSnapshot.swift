import Foundation

/// Everything the watch needs to put the listener back exactly where they
/// stopped: the queue in play order, the order it had before shuffle, the
/// playhead and the player's modes. Tracks are stored by id so the file stays
/// small and survives metadata being rescanned.
public struct WatchPlaybackSnapshot: Codable, Sendable, Equatable {

    public var itemIDs: [String]
    public var originalOrderIDs: [String]
    public var currentIndex: Int
    public var positionSeconds: TimeInterval
    public var isShuffled: Bool
    public var repeatModeRawValue: String
    public var volume: Double
    public var savedAt: Date

    public init(
        itemIDs: [String],
        originalOrderIDs: [String],
        currentIndex: Int,
        positionSeconds: TimeInterval,
        isShuffled: Bool,
        repeatModeRawValue: String,
        volume: Double,
        savedAt: Date
    ) {
        self.itemIDs = itemIDs
        self.originalOrderIDs = originalOrderIDs
        self.currentIndex = currentIndex
        self.positionSeconds = positionSeconds
        self.isShuffled = isShuffled
        self.repeatModeRawValue = repeatModeRawValue
        self.volume = volume
        self.savedAt = savedAt
    }

    public init(
        queue: PlaybackQueue,
        position: TimeInterval,
        repeatMode: RepeatMode,
        volume: Double,
        savedAt: Date = Date()
    ) {
        self.init(
            itemIDs: queue.items.map(\.id),
            originalOrderIDs: queue.originalOrder.map(\.id),
            currentIndex: queue.currentIndex,
            positionSeconds: position,
            isShuffled: queue.isShuffled,
            repeatModeRawValue: repeatMode.rawValue,
            volume: volume,
            savedAt: savedAt
        )
    }

    public var repeatMode: RepeatMode { RepeatMode(rawValue: repeatModeRawValue) ?? .off }

    /// Rebuilds the queue from the tracks still on the watch. Ids that are no
    /// longer in `library` are dropped and the playhead is carried over to the
    /// same track; when that track itself is gone there is nothing honest to
    /// resume and the result is nil. A position at or past the track's end
    /// restarts it instead of resuming in silence.
    public func resolve(in library: [MediaItem]) -> (queue: PlaybackQueue, position: TimeInterval)? {
        guard itemIDs.indices.contains(currentIndex) else { return nil }
        let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard byID[itemIDs[currentIndex]] != nil else { return nil }

        var kept: [MediaItem] = []
        var keptCurrentIndex = 0
        for (index, id) in itemIDs.enumerated() {
            guard let item = byID[id] else { continue }
            if index == currentIndex { keptCurrentIndex = kept.count }
            kept.append(item)
        }
        let queue = PlaybackQueue(
            items: kept,
            originalOrder: originalOrderIDs.compactMap { byID[$0] },
            currentIndex: keptCurrentIndex,
            isShuffled: isShuffled
        )
        guard let current = queue.current else { return nil }
        return (queue, Self.usablePosition(positionSeconds, in: current))
    }

    private static func usablePosition(_ position: TimeInterval, in item: MediaItem) -> TimeInterval {
        guard position.isFinite, position > 0 else { return 0 }
        if item.duration > 0, position >= item.duration { return 0 }
        return position
    }
}
