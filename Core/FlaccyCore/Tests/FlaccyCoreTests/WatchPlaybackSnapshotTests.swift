import XCTest
@testable import FlaccyCore

final class WatchPlaybackSnapshotTests: XCTestCase {

    private let a = queueTestTrack("a"), b = queueTestTrack("b"), c = queueTestTrack("c"), d = queueTestTrack("d")

    private func snapshot(
        ids: [String],
        original: [String]? = nil,
        index: Int,
        position: TimeInterval = 42,
        shuffled: Bool = false
    ) -> WatchPlaybackSnapshot {
        WatchPlaybackSnapshot(
            itemIDs: ids,
            originalOrderIDs: original ?? ids,
            currentIndex: index,
            positionSeconds: position,
            isShuffled: shuffled,
            repeatModeRawValue: RepeatMode.all.rawValue,
            volume: 0.6,
            savedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    func testJSONRoundTrip() throws {
        let original = snapshot(ids: [a.id, b.id], original: [b.id, a.id], index: 1, position: 12.5, shuffled: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WatchPlaybackSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.repeatMode, .all)
    }

    func testUnknownRepeatRawValueFallsBackToOff() {
        var s = snapshot(ids: [a.id], index: 0)
        s.repeatModeRawValue = "sideways"
        XCTAssertEqual(s.repeatMode, .off)
    }

    func testBuildingFromQueueCapturesOrdersAndModes() {
        let q = PlaybackQueue(items: [c, a, b], originalOrder: [a, b, c], currentIndex: 1, isShuffled: true)
        let s = WatchPlaybackSnapshot(queue: q, position: 9, repeatMode: .one, volume: 0.3)
        XCTAssertEqual(s.itemIDs, [c.id, a.id, b.id])
        XCTAssertEqual(s.originalOrderIDs, [a.id, b.id, c.id])
        XCTAssertEqual(s.currentIndex, 1)
        XCTAssertEqual(s.repeatMode, .one)
        XCTAssertTrue(s.isShuffled)
    }

    func testResolveRebuildsTheSameQueue() throws {
        let q = PlaybackQueue(items: [c, a, b], originalOrder: [a, b, c], currentIndex: 2, isShuffled: true)
        let s = WatchPlaybackSnapshot(queue: q, position: 33, repeatMode: .off, volume: 0.5)
        let resolved = try XCTUnwrap(s.resolve(in: [a, b, c, d]))
        XCTAssertEqual(resolved.queue, q)
        XCTAssertEqual(resolved.position, 33)
    }

    func testResolveDropsMissingItemsAndKeepsThePlayhead() throws {
        let s = snapshot(ids: [a.id, b.id, c.id, d.id], index: 2)
        let resolved = try XCTUnwrap(s.resolve(in: [a, c, d]))
        XCTAssertEqual(resolved.queue.items, [a, c, d])
        XCTAssertEqual(resolved.queue.current, c)
        XCTAssertEqual(resolved.queue.currentIndex, 1)
    }

    func testResolveDropsMissingItemsFromTheRememberedOrderToo() throws {
        let s = snapshot(ids: [c.id, a.id, b.id], original: [a.id, b.id, c.id], index: 1, shuffled: true)
        var resolved = try XCTUnwrap(s.resolve(in: [a, c])).queue
        XCTAssertEqual(resolved.originalOrder, [a, c])
        resolved.unshuffle()
        XCTAssertEqual(resolved.items, [a, c])
        XCTAssertEqual(resolved.current, a)
    }

    func testResolveIsNilWhenTheCurrentItemIsGone() {
        let s = snapshot(ids: [a.id, b.id, c.id], index: 1)
        XCTAssertNil(s.resolve(in: [a, c]))
    }

    func testResolveIsNilForEmptyLibraryOrBadIndex() {
        XCTAssertNil(snapshot(ids: [a.id], index: 0).resolve(in: []))
        XCTAssertNil(snapshot(ids: [a.id], index: 4).resolve(in: [a]))
        XCTAssertNil(snapshot(ids: [], index: 0).resolve(in: [a]))
        XCTAssertNil(snapshot(ids: [a.id], index: -1).resolve(in: [a]))
    }

    func testResolveUsesFreshMetadataFromTheLibrary() throws {
        let renamed = MediaItem(
            relativePath: a.relativePath, title: "Renamed", artist: "Artist", albumTitle: "Album",
            trackNumber: 1, duration: 200
        )
        let resolved = try XCTUnwrap(snapshot(ids: [a.id], index: 0).resolve(in: [renamed]))
        XCTAssertEqual(resolved.queue.current?.title, "Renamed")
    }

    func testPositionPastTheEndRestartsTheTrack() throws {
        let past = try XCTUnwrap(snapshot(ids: [a.id], index: 0, position: 250).resolve(in: [a]))
        XCTAssertEqual(past.position, 0)
    }

    func testNegativeOrNonFinitePositionBecomesZero() throws {
        XCTAssertEqual(try XCTUnwrap(snapshot(ids: [a.id], index: 0, position: -5).resolve(in: [a])).position, 0)
        XCTAssertEqual(try XCTUnwrap(snapshot(ids: [a.id], index: 0, position: .nan).resolve(in: [a])).position, 0)
    }

    func testUnknownDurationKeepsTheSavedPosition() throws {
        let unknown = queueTestTrack("a", duration: 0)
        let resolved = try XCTUnwrap(snapshot(ids: [a.id], index: 0, position: 77).resolve(in: [unknown]))
        XCTAssertEqual(resolved.position, 77)
    }
}
