import Foundation

/// The ordered list a player works through, plus everything needed to edit it
/// without losing the listener's place.
///
/// The value remembers the order the music had before it was shuffled, so
/// switching shuffle off puts the queue back the way it was, including tracks
/// added while it was shuffled. Entries carry a private token so the same song
/// queued twice is two distinct rows rather than one ambiguous match.
public struct PlaybackQueue: Sendable, Equatable {

    private struct Entry: Sendable {
        let token: Int
        let item: MediaItem
    }

    private var entries: [Entry]
    private var originalEntries: [Entry]
    private var nextToken: Int

    public private(set) var currentIndex: Int
    public private(set) var isShuffled: Bool

    public init() {
        entries = []
        originalEntries = []
        nextToken = 0
        currentIndex = 0
        isShuffled = false
    }

    public init(items: [MediaItem], startingAt index: Int = 0, shuffled: Bool = false) {
        var generator = SystemRandomNumberGenerator()
        self.init(items: items, startingAt: index, shuffled: shuffled, using: &generator)
    }

    public init<G: RandomNumberGenerator>(
        items: [MediaItem],
        startingAt index: Int = 0,
        shuffled: Bool = false,
        using generator: inout G
    ) {
        self.init()
        let made = makeEntries(items)
        entries = made
        originalEntries = made
        currentIndex = items.indices.contains(index) ? index : 0
        if shuffled { shuffle(keepingCurrent: true, using: &generator) }
    }

    /// Rebuilds a queue from a saved play order and the order it had before it
    /// was shuffled. Items missing from `originalOrder` keep their place at
    /// the end; items in it that are not in `items` are ignored.
    public init(items: [MediaItem], originalOrder: [MediaItem], currentIndex: Int, isShuffled: Bool) {
        self.init()
        let made = makeEntries(items)
        entries = made
        self.currentIndex = items.indices.contains(currentIndex) ? currentIndex : 0
        self.isShuffled = isShuffled && !items.isEmpty
        originalEntries = self.isShuffled ? Self.arrange(made, like: originalOrder) : made
    }

    public var items: [MediaItem] { entries.map(\.item) }

    /// The order the music had before shuffle was switched on; equal to
    /// `items` while the queue is not shuffled.
    public var originalOrder: [MediaItem] { originalEntries.map(\.item) }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    public var current: MediaItem? {
        entries.indices.contains(currentIndex) ? entries[currentIndex].item : nil
    }

    /// Everything that will play after the current item, in play order.
    public var upNext: [MediaItem] {
        guard currentIndex + 1 < entries.count else { return [] }
        return entries[(currentIndex + 1)...].map(\.item)
    }

    /// Everything that has already played, oldest first.
    public var history: [MediaItem] {
        guard currentIndex > 0, currentIndex <= entries.count else { return [] }
        return entries[..<currentIndex].map(\.item)
    }

    public var hasNext: Bool { currentIndex + 1 < entries.count }

    public func item(at index: Int) -> MediaItem? {
        entries.indices.contains(index) ? entries[index].item : nil
    }

    public static func == (lhs: PlaybackQueue, rhs: PlaybackQueue) -> Bool {
        lhs.currentIndex == rhs.currentIndex
            && lhs.isShuffled == rhs.isShuffled
            && lhs.items == rhs.items
            && lhs.originalOrder == rhs.originalOrder
    }

    /// Moves the playhead to `index`. Returns false when it is out of range.
    @discardableResult
    public mutating func jump(to index: Int) -> Bool {
        guard entries.indices.contains(index) else { return false }
        currentIndex = index
        return true
    }

    /// Puts `newItems` straight after the current item, in the order given.
    /// Each call lands ahead of anything queued by an earlier call. On an empty
    /// queue the first new item becomes the current one.
    public mutating func playNext(_ newItems: [MediaItem]) {
        guard !newItems.isEmpty else { return }
        let added = makeEntries(newItems)
        guard !entries.isEmpty else {
            entries = added
            originalEntries = added
            currentIndex = 0
            return
        }
        entries.insert(contentsOf: added, at: currentIndex + 1)
        originalEntries.insert(contentsOf: added, at: originalInsertionIndexAfterCurrent())
    }

    /// Appends `newItems` to the end of the queue. On an empty queue the first
    /// new item becomes the current one.
    public mutating func enqueue(_ newItems: [MediaItem]) {
        guard !newItems.isEmpty else { return }
        let added = makeEntries(newItems)
        entries.append(contentsOf: added)
        originalEntries.append(contentsOf: added)
        if entries.count == added.count { currentIndex = 0 }
    }

    /// Removes the row at `index`. The current item can never be removed, and
    /// the playhead keeps pointing at the same item when an earlier row goes.
    @discardableResult
    public mutating func remove(at index: Int) -> Bool {
        guard entries.indices.contains(index), index != currentIndex else { return false }
        let token = entries[index].token
        entries.remove(at: index)
        originalEntries.removeAll { $0.token == token }
        if index < currentIndex { currentIndex -= 1 }
        return true
    }

    /// Drops everything after the current item.
    public mutating func clearUpNext() {
        guard hasNext else { return }
        let dropped = Set(entries[(currentIndex + 1)...].map(\.token))
        entries.removeSubrange((currentIndex + 1)...)
        originalEntries.removeAll { dropped.contains($0.token) }
    }

    public mutating func shuffle(keepingCurrent: Bool = true) {
        var generator = SystemRandomNumberGenerator()
        shuffle(keepingCurrent: keepingCurrent, using: &generator)
    }

    /// Shuffles the whole queue and remembers the order it had. With
    /// `keepingCurrent` the playing item moves to the front and keeps playing;
    /// without it every item is shuffled and the playhead lands on whichever
    /// item comes out first. Shuffling again keeps the first remembered order.
    public mutating func shuffle<G: RandomNumberGenerator>(keepingCurrent: Bool = true, using generator: inout G) {
        isShuffled = true
        guard entries.count > 1 else { return }
        if keepingCurrent, entries.indices.contains(currentIndex) {
            var rest = entries
            let playing = rest.remove(at: currentIndex)
            rest.shuffle(using: &generator)
            entries = [playing] + rest
        } else {
            entries.shuffle(using: &generator)
        }
        currentIndex = 0
    }

    /// Restores the pre-shuffle order, keeping the playing item playing.
    public mutating func unshuffle() {
        let playingToken = entries.indices.contains(currentIndex) ? entries[currentIndex].token : nil
        isShuffled = false
        entries = originalEntries
        currentIndex = playingToken.flatMap { token in entries.firstIndex { $0.token == token } } ?? 0
    }

    private mutating func makeEntries(_ items: [MediaItem]) -> [Entry] {
        items.map { item in
            defer { nextToken += 1 }
            return Entry(token: nextToken, item: item)
        }
    }

    /// Where new "play next" rows belong in the remembered order: right after
    /// the playing item's own place there, which is not its shuffled place.
    private func originalInsertionIndexAfterCurrent() -> Int {
        guard entries.indices.contains(currentIndex) else { return originalEntries.count }
        let token = entries[currentIndex].token
        guard let position = originalEntries.firstIndex(where: { $0.token == token }) else {
            return originalEntries.count
        }
        return position + 1
    }

    private static func arrange(_ entries: [Entry], like order: [MediaItem]) -> [Entry] {
        var pool: [String: [Entry]] = [:]
        for entry in entries.reversed() { pool[entry.item.id, default: []].append(entry) }
        var arranged: [Entry] = []
        var taken = Set<Int>()
        for item in order {
            guard let entry = pool[item.id]?.popLast() else { continue }
            arranged.append(entry)
            taken.insert(entry.token)
        }
        arranged.append(contentsOf: entries.filter { !taken.contains($0.token) })
        return arranged
    }
}
