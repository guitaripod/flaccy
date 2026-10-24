import XCTest
@testable import FlaccyCore

final class WatchPlayTrackerTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func tracker(duration: TimeInterval = 200) -> WatchPlayTracker {
        var tracker = WatchPlayTracker()
        tracker.begin(path: "A/B/01.m4a", title: "Song", artist: "Artist", album: "Album", duration: duration, at: start)
        return tracker
    }

    private func listen(_ tracker: inout WatchPlayTracker, from: TimeInterval = 0, seconds: Int, step: TimeInterval = 1) {
        var elapsed = from
        for _ in 0..<Int(Double(seconds) / step) {
            elapsed += step
            tracker.advance(to: elapsed, isPlaying: true)
        }
    }

    func testPlayingToTheHalfwayPointQualifies() {
        var tracker = tracker(duration: 200)
        listen(&tracker, seconds: 100)
        let entry = tracker.finish(now: start.addingTimeInterval(100))
        XCTAssertEqual(entry?.path, "A/B/01.m4a")
        XCTAssertEqual(entry?.title, "Song")
        XCTAssertEqual(entry?.artist, "Artist")
        XCTAssertEqual(entry?.album, "Album")
        XCTAssertEqual(entry?.durationSeconds, 200)
    }

    func testStartedAtIsTheBeginTimeNotTheFinishTime() {
        var tracker = tracker(duration: 100)
        listen(&tracker, seconds: 60)
        let entry = tracker.finish(now: start.addingTimeInterval(9_999))
        XCTAssertEqual(entry?.startedAt, start)
    }

    func testJustUnderTheThresholdDoesNotQualify() {
        var tracker = tracker(duration: 200)
        listen(&tracker, seconds: 99)
        XCTAssertNil(tracker.finish(now: start))
    }

    func testLongTracksNeedAtMostFourMinutes() {
        var tracker = tracker(duration: 1_200)
        listen(&tracker, seconds: 239)
        XCTAssertNil(tracker.finish(now: start))
        var enough = self.tracker(duration: 1_200)
        listen(&enough, seconds: 240)
        XCTAssertNotNil(enough.finish(now: start))
    }

    func testTracksUnderThirtySecondsNeverQualify() {
        var tracker = tracker(duration: 20)
        listen(&tracker, seconds: 20)
        XCTAssertNil(tracker.finish(now: start))
    }

    func testThirtySecondFloorForShortTracks() {
        var tracker = tracker(duration: 40)
        listen(&tracker, seconds: 29)
        XCTAssertNil(tracker.finish(now: start))
        var enough = self.tracker(duration: 40)
        listen(&enough, seconds: 30)
        XCTAssertNotNil(enough.finish(now: start))
    }

    func testUnknownDurationNeverQualifies() {
        var tracker = tracker(duration: 0)
        listen(&tracker, seconds: 600)
        XCTAssertNil(tracker.finish(now: start))
    }

    func testSeekingForwardDoesNotCountAsListening() {
        var tracker = tracker(duration: 200)
        listen(&tracker, seconds: 10)
        tracker.advance(to: 150, isPlaying: true)
        XCTAssertEqual(tracker.playedSeconds, 10, accuracy: 0.001)
        listen(&tracker, from: 150, seconds: 5)
        XCTAssertEqual(tracker.playedSeconds, 15, accuracy: 0.001)
        XCTAssertNil(tracker.finish(now: start))
    }

    func testSeekingBackwardDoesNotCountAndDoesNotRemoveCredit() {
        var tracker = tracker(duration: 200)
        listen(&tracker, seconds: 40)
        tracker.advance(to: 5, isPlaying: true)
        XCTAssertEqual(tracker.playedSeconds, 40, accuracy: 0.001)
        listen(&tracker, from: 5, seconds: 3)
        XCTAssertEqual(tracker.playedSeconds, 43, accuracy: 0.001)
    }

    func testScrubbingAcrossTheTrackNeverQualifies() {
        var tracker = tracker(duration: 200)
        for position in stride(from: 10.0, through: 190.0, by: 10.0) {
            tracker.advance(to: position, isPlaying: true)
        }
        XCTAssertNil(tracker.finish(now: start))
    }

    func testPausedTimeDoesNotCount() {
        var tracker = tracker(duration: 100)
        listen(&tracker, seconds: 20)
        for _ in 0..<300 { tracker.advance(to: 20, isPlaying: false) }
        XCTAssertEqual(tracker.playedSeconds, 20, accuracy: 0.001)
    }

    func testProgressReportedWhilePausedDoesNotCountButMovesTheBaseline() {
        var tracker = tracker(duration: 100)
        tracker.advance(to: 1.5, isPlaying: false)
        tracker.advance(to: 3.0, isPlaying: true)
        XCTAssertEqual(tracker.playedSeconds, 1.5, accuracy: 0.001)
    }

    func testStepOfExactlyTwoSecondsCounts() {
        var tracker = tracker(duration: 100)
        tracker.advance(to: 2, isPlaying: true)
        XCTAssertEqual(tracker.playedSeconds, 2, accuracy: 0.001)
        tracker.advance(to: 4.01, isPlaying: true)
        XCTAssertEqual(tracker.playedSeconds, 2, accuracy: 0.001)
    }

    func testRepeatedReadingsOfTheSamePositionAddNothing() {
        var tracker = tracker(duration: 100)
        tracker.advance(to: 1, isPlaying: true)
        for _ in 0..<10 { tracker.advance(to: 1, isPlaying: true) }
        XCTAssertEqual(tracker.playedSeconds, 1, accuracy: 0.001)
    }

    func testNonFiniteElapsedIsIgnored() {
        var tracker = tracker(duration: 100)
        tracker.advance(to: .nan, isPlaying: true)
        tracker.advance(to: .infinity, isPlaying: true)
        tracker.advance(to: 1, isPlaying: true)
        XCTAssertEqual(tracker.playedSeconds, 1, accuracy: 0.001)
    }

    func testFinishYieldsAtMostOncePerBegin() {
        var tracker = tracker(duration: 60)
        listen(&tracker, seconds: 40)
        XCTAssertNotNil(tracker.finish(now: start))
        XCTAssertNil(tracker.finish(now: start))
        XCTAssertFalse(tracker.isTracking)
    }

    func testFinishWithoutBeginIsNil() {
        var tracker = WatchPlayTracker()
        XCTAssertNil(tracker.finish(now: start))
        tracker.advance(to: 10, isPlaying: true)
        XCTAssertEqual(tracker.playedSeconds, 0)
    }

    func testAdvanceAfterFinishDoesNothing() {
        var tracker = tracker(duration: 60)
        listen(&tracker, seconds: 40)
        _ = tracker.finish(now: start)
        tracker.advance(to: 41, isPlaying: true)
        XCTAssertNil(tracker.finish(now: start))
    }

    func testRepeatOneReplayIsAnotherPlayWithItsOwnIdAndStart() {
        var tracker = WatchPlayTracker()
        tracker.begin(path: "A/01.m4a", title: "Song", artist: "Artist", album: "Album", duration: 60, at: start)
        listen(&tracker, seconds: 58)
        let first = tracker.finish(now: start.addingTimeInterval(58))

        let second = start.addingTimeInterval(60)
        tracker.begin(path: "A/01.m4a", title: "Song", artist: "Artist", album: "Album", duration: 60, at: second)
        listen(&tracker, seconds: 58)
        let replay = tracker.finish(now: second.addingTimeInterval(58))

        XCTAssertNotNil(first)
        XCTAssertNotNil(replay)
        XCTAssertNotEqual(first?.id, replay?.id)
        XCTAssertEqual(first?.startedAt, start)
        XCTAssertEqual(replay?.startedAt, second)
    }

    func testReplayStartsCountingFromZero() {
        var tracker = tracker(duration: 60)
        listen(&tracker, seconds: 58)
        _ = tracker.finish(now: start)
        tracker.begin(path: "A/01.m4a", title: "Song", artist: "Artist", album: "Album", duration: 60, at: start)
        XCTAssertEqual(tracker.playedSeconds, 0)
        listen(&tracker, seconds: 5)
        XCTAssertNil(tracker.finish(now: start))
    }

    func testBeginDropsAnUnfinishedPlay() {
        var tracker = tracker(duration: 60)
        listen(&tracker, seconds: 50)
        tracker.begin(path: "A/02.m4a", title: "Next", artist: "Artist", album: "Album", duration: 60, at: start)
        XCTAssertEqual(tracker.playedSeconds, 0)
        XCTAssertNil(tracker.finish(now: start))
    }

    func testEntryPathIsCanonical() {
        var tracker = WatchPlayTracker()
        tracker.begin(path: "Bjo\u{308}rk/01.m4a", title: "", artist: "", album: "", duration: 60, at: start)
        listen(&tracker, seconds: 40)
        XCTAssertEqual(tracker.finish(now: start)?.path, "Bjo\u{308}rk/01.m4a".precomposedStringWithCanonicalMapping)
    }

    func testEntryRoundTripsThroughItsDictionary() {
        var tracker = tracker(duration: 100)
        listen(&tracker, seconds: 60)
        let entry = tracker.finish(now: start)
        XCTAssertEqual(WatchPlayEntry(dictionary: entry?.dictionary), entry)
    }
}
