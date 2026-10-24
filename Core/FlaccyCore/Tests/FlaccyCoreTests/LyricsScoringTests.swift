import XCTest
@testable import FlaccyCore

final class LyricsScoringTests: XCTestCase {

    private func wanted(_ duration: Double) -> LyricsWanted {
        LyricsWanted(title: "Song", artist: "Artist", album: "Album", duration: duration)
    }

    private func candidate(_ title: String, _ duration: Double, _ synced: Bool, _ words: Bool) -> LyricsCandidate {
        LyricsCandidate(
            title: title, artist: "Artist", album: "Album", duration: duration,
            hasSynced: synced, hasWordSync: words)
    }

    func testDurationDriftDisqualifiesACandidate() {
        XCTAssertNil(LyricsScoring.score(wanted(200.0), candidate("Song", 400.0, true, false)))
        XCTAssertNotNil(LyricsScoring.score(wanted(200.0), candidate("Song", 215.0, true, false)))
        XCTAssertNil(LyricsScoring.score(wanted(200.0), candidate("Song", 215.1, true, false)))
    }

    func testAnExactMatchClearsTheThreshold() throws {
        let value = try XCTUnwrap(LyricsScoring.score(wanted(200.0), candidate("Song", 200.0, true, false)))
        XCTAssertEqual(value, 1.0, accuracy: 1e-9)
    }

    func testADifferentSongFallsShort() throws {
        let other = LyricsCandidate(
            title: "Something Else Entirely", artist: "Other Band", album: "Nope",
            duration: 199.0, hasSynced: false, hasWordSync: false)
        let value = try XCTUnwrap(LyricsScoring.score(wanted(200.0), other))
        XCTAssertLessThan(value, LyricsScoring.acceptedScore)
    }

    func testAnUnknownDurationScoresNeutrally() throws {
        let value = try XCTUnwrap(LyricsScoring.score(wanted(0.0), candidate("Song", 180.0, true, false)))
        XCTAssertEqual(value, 0.35 + 0.30 + 0.125 + 0.06 + 0.04, accuracy: 1e-9)
    }

    func testWordTimingBreaksATieWithoutChangingTheWinnerClass() throws {
        let plain = candidate("Song", 200.0, true, false)
        let timed = candidate("Song", 200.0, true, true)
        let picked = try XCTUnwrap(LyricsScoring.bestCandidate(wanted(200.0), [plain, timed]))
        XCTAssertEqual(picked.index, 1)
    }

    func testNothingBelowTheThresholdIsPicked() {
        let other = candidate("Another Tune", 200.0, true, true)
        XCTAssertNil(LyricsScoring.bestCandidate(wanted(200.0), [other]))
    }

    func testSimilarityIgnoresCaseAndPunctuation() {
        XCTAssertEqual(LyricsScoring.similarity("Hello, World!", "hello world"), 1.0)
        XCTAssertEqual(LyricsScoring.similarity("a b", "c d"), 0.0)
        XCTAssertEqual(LyricsScoring.similarity("", "x"), 0.0)
        XCTAssertEqual(LyricsScoring.similarity("Song (Remastered 2011)", "Song"), 0.5, accuracy: 1e-9)
    }

    func testTheFirstCandidateWinsATie() throws {
        let one = candidate("Song", 200.0, true, false)
        let picked = try XCTUnwrap(LyricsScoring.bestCandidate(wanted(200.0), [one, one]))
        XCTAssertEqual(picked.index, 0)
    }
}
