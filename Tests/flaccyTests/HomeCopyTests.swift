import FlaccyCore
import XCTest
@testable import flaccy

nonisolated final class HomeCopyTests: XCTestCase {

    @MainActor func testRemainingRoundsMinutesUpAndNeverReadsZero() {
        XCTAssertEqual(HomeCopy.remaining(1_080), "18 min left")
        XCTAssertEqual(HomeCopy.remaining(1_081), "19 min left")
        XCTAssertEqual(HomeCopy.remaining(3), "1 min left")
        XCTAssertEqual(HomeCopy.remaining(3_900), "1 h 5 min left")
    }

    @MainActor func testDurationRoundsToTheNearestMinuteAndSplitsHours() {
        XCTAssertEqual(HomeCopy.duration(2_280), "38 min")
        XCTAssertEqual(HomeCopy.duration(20), "1 min")
        XCTAssertEqual(HomeCopy.duration(5_880), "1 h 38 min")
    }

    @MainActor func testMixMetaJoinsCountAndDuration() {
        XCTAssertEqual(HomeCopy.mixMeta(count: 43, seconds: 11_940), "43 songs · 3 h 19 min")
    }

    @MainActor func testStartsWithNamesAtMostFourAlbums() {
        XCTAssertNil(HomeCopy.startsWith([]))
        XCTAssertEqual(HomeCopy.startsWith(["Aurorae"]), "Starts with Aurorae")
        XCTAssertEqual(HomeCopy.startsWith(["Aurorae", "Cassini"]), "Starts with Aurorae and Cassini")
        XCTAssertEqual(
            HomeCopy.startsWith(["Aurorae", "Cassini", "Midnatt"]), "Starts with Aurorae, Cassini and Midnatt"
        )
        XCTAssertEqual(
            HomeCopy.startsWith(["Aurorae", "Cassini", "Midnatt", "Ravine", "Statuary"]),
            "Starts with Aurorae, Cassini, Midnatt and Ravine"
        )
    }

    @MainActor func testListeningTruncatesLikeRecap() {
        XCTAssertEqual(HomeCopy.listening(51_359), "14 h 15 m")
        XCTAssertEqual(HomeCopy.listening(2_759), "45 min")
        XCTAssertEqual(HomeCopy.listening(0), "0 min")
    }

    @MainActor func testDeltaSpellsEveryOutcome() {
        XCTAssertEqual(HomeCopy.delta(.up(12)), "▲ 12%")
        XCTAssertEqual(HomeCopy.delta(.down(5)), "▼ 5%")
        XCTAssertEqual(HomeCopy.delta(.even), "Even")
        XCTAssertEqual(HomeCopy.delta(.new), "New")
        XCTAssertNil(HomeCopy.delta(.none))
    }

    @MainActor func testTrackLineNumbersFromOne() {
        XCTAssertEqual(HomeCopy.trackLine(index: 5, title: "Slow Machine"), "5 · Slow Machine")
    }

    @MainActor func testPlaysAndSongCountPluralise() {
        XCTAssertEqual(HomeCopy.plays(36), "36 plays")
        XCTAssertEqual(HomeCopy.songCount(9), "9 songs")
    }
}
