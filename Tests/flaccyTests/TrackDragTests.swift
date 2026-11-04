import FlaccyCore
import XCTest
@testable import FlaccyEngine
@testable import flaccy

/// Songs dropped into Up Next land after the first `position` songs already
/// waiting, in the order they were dragged, against a queue that behaves like
/// the engine's: `insertNext` puts a song straight after the current one and
/// `moveInQueue` removes then inserts.
nonisolated final class TrackDragTests: XCTestCase {

    @MainActor private final class Queue: UpNextEditing {
        var queue: [Track]
        var currentIndex: Int

        init(_ titles: [String], current: Int) {
            queue = titles.map(TrackDragTests.track)
            currentIndex = current
        }

        var currentTrack: Track? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }
        var titles: [String] { queue.map(\.title) }

        func insertNext(_ track: Track) {
            queue.insert(track, at: min(currentIndex + 1, queue.count))
        }

        func addToQueue(_ track: Track) {
            queue.append(track)
        }

        func moveInQueue(from sourceIndex: Int, to destinationIndex: Int) {
            let playing = currentTrack
            let moved = queue.remove(at: sourceIndex)
            queue.insert(moved, at: destinationIndex)
            if let playing, let index = queue.firstIndex(of: playing) { currentIndex = index }
        }
    }

    nonisolated static func track(_ title: String) -> Track {
        Track(
            fileURL: URL(fileURLWithPath: "/drag-test/\(title).flac"), title: title, artist: "A", albumTitle: "B",
            albumArtist: nil, trackNumber: 1, duration: 60, artwork: nil, dbID: nil
        )
    }

    @MainActor func testDropOnTheFirstWaitingSongPlaysTheSongsNextInOrder() {
        let queue = Queue(["played", "now", "a", "b"], current: 1)
        TrackDrag.insertInUpNext([Self.track("x"), Self.track("y")], at: 0, in: queue)
        XCTAssertEqual(queue.titles, ["played", "now", "x", "y", "a", "b"])
        XCTAssertEqual(queue.currentIndex, 1)
    }

    @MainActor func testDropBetweenWaitingSongsLandsBetweenThem() {
        let queue = Queue(["now", "a", "b", "c"], current: 0)
        TrackDrag.insertInUpNext([Self.track("x"), Self.track("y")], at: 2, in: queue)
        XCTAssertEqual(queue.titles, ["now", "a", "b", "x", "y", "c"])
        XCTAssertEqual(queue.currentIndex, 0)
    }

    @MainActor func testDropBelowTheListOrPastItsEndJoinsTheEnd() {
        let queue = Queue(["now", "a"], current: 0)
        TrackDrag.insertInUpNext([Self.track("x")], at: 1, in: queue)
        TrackDrag.insertInUpNext([Self.track("y")], at: 99, in: queue)
        XCTAssertEqual(queue.titles, ["now", "a", "x", "y"])
    }

    @MainActor func testDropWithNothingPlayingQueuesTheSongs() {
        let queue = Queue([], current: 0)
        TrackDrag.insertInUpNext([Self.track("x"), Self.track("y")], at: 0, in: queue)
        XCTAssertEqual(queue.titles, ["x", "y"])
    }
}
