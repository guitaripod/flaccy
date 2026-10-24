import XCTest
@testable import FlaccyCore

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func queueTestTrack(_ name: String, duration: TimeInterval = 200) -> MediaItem {
    MediaItem(
        relativePath: "Artist/Album/\(name).flac",
        title: name,
        artist: "Artist",
        albumTitle: "Album",
        trackNumber: 1,
        duration: duration
    )
}

final class PlaybackQueueTests: XCTestCase {

    private let a = queueTestTrack("a"), b = queueTestTrack("b"), c = queueTestTrack("c"), d = queueTestTrack("d"), e = queueTestTrack("e")

    private func queue(_ items: [MediaItem], at index: Int = 0) -> PlaybackQueue {
        PlaybackQueue(items: items, startingAt: index)
    }

    func testEmptyQueueHasNoCurrentAndIgnoresEdits() {
        var q = PlaybackQueue()
        XCTAssertTrue(q.isEmpty)
        XCTAssertNil(q.current)
        XCTAssertEqual(q.upNext, [])
        XCTAssertEqual(q.history, [])
        XCTAssertFalse(q.remove(at: 0))
        XCTAssertFalse(q.jump(to: 0))
        q.clearUpNext()
        q.unshuffle()
        q.shuffle()
        XCTAssertTrue(q.isEmpty)
        XCTAssertTrue(q.isShuffled)
    }

    func testStartingIndexAndViews() {
        let q = queue([a, b, c, d], at: 2)
        XCTAssertEqual(q.current, c)
        XCTAssertEqual(q.upNext, [d])
        XCTAssertEqual(q.history, [a, b])
        XCTAssertTrue(q.hasNext)
    }

    func testOutOfRangeStartFallsBackToFirst() {
        XCTAssertEqual(queue([a, b], at: 9).currentIndex, 0)
        XCTAssertEqual(queue([a, b], at: -1).currentIndex, 0)
    }

    func testPlayNextInsertsAfterCurrentInGivenOrder() {
        var q = queue([a, b, c], at: 1)
        q.playNext([d, e])
        XCTAssertEqual(q.items, [a, b, d, e, c])
        XCTAssertEqual(q.current, b)
        XCTAssertEqual(q.upNext, [d, e, c])
    }

    func testSecondPlayNextLandsAheadOfTheFirst() {
        var q = queue([a, b])
        q.playNext([c])
        q.playNext([d])
        XCTAssertEqual(q.items, [a, d, c, b])
    }

    func testPlayNextOnEmptyQueueMakesFirstItemCurrent() {
        var q = PlaybackQueue()
        q.playNext([a, b])
        XCTAssertEqual(q.items, [a, b])
        XCTAssertEqual(q.current, a)
    }

    func testPlayNextWithNothingIsANoOp() {
        var q = queue([a, b])
        q.playNext([])
        XCTAssertEqual(q.items, [a, b])
    }

    func testEnqueueAppendsAndKeepsCurrent() {
        var q = queue([a, b], at: 1)
        q.enqueue([c, d])
        XCTAssertEqual(q.items, [a, b, c, d])
        XCTAssertEqual(q.current, b)
    }

    func testEnqueueOnEmptyQueueMakesFirstItemCurrent() {
        var q = PlaybackQueue()
        q.enqueue([c, d])
        XCTAssertEqual(q.current, c)
        XCTAssertEqual(q.upNext, [d])
    }

    func testSameTrackQueuedTwiceIsTwoRows() {
        var q = queue([a, b])
        q.enqueue([b])
        XCTAssertEqual(q.items, [a, b, b])
        XCTAssertTrue(q.remove(at: 2))
        XCTAssertEqual(q.items, [a, b])
    }

    func testRemoveAfterCurrentKeepsIndex() {
        var q = queue([a, b, c, d], at: 1)
        XCTAssertTrue(q.remove(at: 3))
        XCTAssertEqual(q.items, [a, b, c])
        XCTAssertEqual(q.currentIndex, 1)
        XCTAssertEqual(q.current, b)
    }

    func testRemoveBeforeCurrentShiftsIndexDown() {
        var q = queue([a, b, c, d], at: 2)
        XCTAssertTrue(q.remove(at: 0))
        XCTAssertEqual(q.items, [b, c, d])
        XCTAssertEqual(q.currentIndex, 1)
        XCTAssertEqual(q.current, c)
    }

    func testRemoveCurrentIsRefused() {
        var q = queue([a, b, c], at: 1)
        XCTAssertFalse(q.remove(at: 1))
        XCTAssertEqual(q.items, [a, b, c])
    }

    func testRemoveOutOfRangeIsRefused() {
        var q = queue([a, b])
        XCTAssertFalse(q.remove(at: 5))
        XCTAssertFalse(q.remove(at: -1))
        XCTAssertEqual(q.items, [a, b])
    }

    func testSingleItemQueueCannotLoseItsOnlyRow() {
        var q = queue([a])
        XCTAssertFalse(q.remove(at: 0))
        q.clearUpNext()
        XCTAssertEqual(q.items, [a])
        XCTAssertEqual(q.upNext, [])
    }

    func testClearUpNextKeepsHistoryAndCurrent() {
        var q = queue([a, b, c, d], at: 1)
        q.clearUpNext()
        XCTAssertEqual(q.items, [a, b])
        XCTAssertEqual(q.current, b)
        XCTAssertEqual(q.history, [a])
        XCTAssertEqual(q.upNext, [])
    }

    func testJumpMovesThePlayhead() {
        var q = queue([a, b, c])
        XCTAssertTrue(q.jump(to: 2))
        XCTAssertEqual(q.current, c)
        XCTAssertFalse(q.jump(to: 3))
        XCTAssertEqual(q.current, c)
    }

    func testShuffleKeepsCurrentFirstAndEveryItem() {
        var generator = SeededGenerator(state: 7)
        var q = PlaybackQueue(items: [a, b, c, d, e], startingAt: 2)
        q.shuffle(keepingCurrent: true, using: &generator)
        XCTAssertEqual(q.currentIndex, 0)
        XCTAssertEqual(q.current, c)
        XCTAssertTrue(q.isShuffled)
        XCTAssertEqual(Set(q.items), Set([a, b, c, d, e]))
        XCTAssertEqual(q.count, 5)
        XCTAssertEqual(q.originalOrder, [a, b, c, d, e])
    }

    func testShuffleThenUnshuffleRestoresOrderAndCurrent() {
        var generator = SeededGenerator(state: 99)
        var q = PlaybackQueue(items: [a, b, c, d, e], startingAt: 3)
        q.shuffle(keepingCurrent: true, using: &generator)
        q.jump(to: 2)
        let playing = q.current
        q.unshuffle()
        XCTAssertFalse(q.isShuffled)
        XCTAssertEqual(q.items, [a, b, c, d, e])
        XCTAssertEqual(q.current, playing)
    }

    func testShuffleWithoutKeepingCurrentShufflesEverythingAndStartsAtTop() {
        var generator = SeededGenerator(state: 3)
        var q = PlaybackQueue(items: [a, b, c, d, e], startingAt: 2)
        q.shuffle(keepingCurrent: false, using: &generator)
        XCTAssertEqual(q.currentIndex, 0)
        XCTAssertEqual(Set(q.items), Set([a, b, c, d, e]))
    }

    func testReshuffleKeepsTheFirstRememberedOrder() {
        var generator = SeededGenerator(state: 11)
        var q = PlaybackQueue(items: [a, b, c, d, e])
        q.shuffle(keepingCurrent: true, using: &generator)
        q.shuffle(keepingCurrent: true, using: &generator)
        q.unshuffle()
        XCTAssertEqual(q.items, [a, b, c, d, e])
    }

    func testShuffleFlagSticksOnSingleItemQueue() {
        var q = queue([a])
        q.shuffle()
        XCTAssertTrue(q.isShuffled)
        XCTAssertEqual(q.items, [a])
        q.unshuffle()
        XCTAssertFalse(q.isShuffled)
        XCTAssertEqual(q.current, a)
    }

    func testInitShuffledPutsChosenTrackFirst() {
        var generator = SeededGenerator(state: 5)
        let q = PlaybackQueue(items: [a, b, c, d], startingAt: 2, shuffled: true, using: &generator)
        XCTAssertEqual(q.current, c)
        XCTAssertEqual(q.currentIndex, 0)
        XCTAssertEqual(q.originalOrder, [a, b, c, d])
    }

    func testPlayNextWhileShuffledSurvivesUnshuffleRightAfterTheCurrentTrack() {
        var generator = SeededGenerator(state: 21)
        var q = PlaybackQueue(items: [a, b, c, d], startingAt: 1)
        q.shuffle(keepingCurrent: true, using: &generator)
        q.playNext([e])
        XCTAssertEqual(q.items[1], e)
        q.unshuffle()
        XCTAssertEqual(q.items, [a, b, e, c, d])
        XCTAssertEqual(q.current, b)
    }

    func testEnqueueWhileShuffledLandsAtTheEndOfBothOrders() {
        var generator = SeededGenerator(state: 8)
        var q = PlaybackQueue(items: [a, b, c], startingAt: 0)
        q.shuffle(keepingCurrent: true, using: &generator)
        q.enqueue([d])
        XCTAssertEqual(q.items.last, d)
        q.unshuffle()
        XCTAssertEqual(q.items, [a, b, c, d])
    }

    func testRemoveWhileShuffledAlsoLeavesTheRememberedOrder() {
        var generator = SeededGenerator(state: 13)
        var q = PlaybackQueue(items: [a, b, c, d], startingAt: 0)
        q.shuffle(keepingCurrent: true, using: &generator)
        let victim = q.items[2]
        XCTAssertTrue(q.remove(at: 2))
        q.unshuffle()
        XCTAssertFalse(q.items.contains(victim))
        XCTAssertEqual(q.count, 3)
    }

    func testClearUpNextWhileShuffledLeavesOnlyHistoryAndCurrentInBothOrders() {
        var generator = SeededGenerator(state: 17)
        var q = PlaybackQueue(items: [a, b, c, d, e], startingAt: 0)
        q.shuffle(keepingCurrent: true, using: &generator)
        q.jump(to: 2)
        let kept = Set(q.items[0...2])
        q.clearUpNext()
        q.unshuffle()
        XCTAssertEqual(Set(q.items), kept)
    }

    func testRestoringInitCarriesShuffledStateAndOriginalOrder() {
        let q = PlaybackQueue(items: [c, a, b], originalOrder: [a, b, c], currentIndex: 1, isShuffled: true)
        XCTAssertEqual(q.current, a)
        XCTAssertEqual(q.originalOrder, [a, b, c])
        var copy = q
        copy.unshuffle()
        XCTAssertEqual(copy.items, [a, b, c])
        XCTAssertEqual(copy.current, a)
    }

    func testRestoringInitIgnoresStrangersAndAppendsStragglers() {
        let q = PlaybackQueue(items: [c, a, b], originalOrder: [a, d], currentIndex: 0, isShuffled: true)
        XCTAssertEqual(q.originalOrder, [a, c, b])
    }

    func testRestoringInitClampsABadIndex() {
        let q = PlaybackQueue(items: [a, b], originalOrder: [a, b], currentIndex: 8, isShuffled: false)
        XCTAssertEqual(q.currentIndex, 0)
    }
}
