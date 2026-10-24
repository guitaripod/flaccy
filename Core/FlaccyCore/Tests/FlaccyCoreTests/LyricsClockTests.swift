import XCTest
@testable import FlaccyCore

final class LyricsClockTests: XCTestCase {

    private func raw(_ start: Double, _ end: Double?, _ text: String) -> LyricsRawLine {
        LyricsRawLine(start: start, end: end, text: text, words: [])
    }

    private func song() -> LyricsDocument {
        LyricsDocument.resolve(
            raw: [
                raw(1.0, 3.0, "one"),
                raw(3.5, 6.0, "two"),
                raw(20.0, 24.0, "three"),
            ],
            plain: nil, instrumental: false)
    }

    private func singingLine() throws -> LyricsLine {
        let line = LyricsRawLine(
            start: 10.0, end: 14.0, text: "",
            words: [
                LyricsRawWord(start: 10.0, end: 11.0, text: "Stay "),
                LyricsRawWord(start: 11.0, end: 12.0, text: "until "),
                LyricsRawWord(start: 13.0, end: 14.0, text: "dawn"),
            ])
        let doc = LyricsDocument.resolve(raw: [line], plain: nil, instrumental: false)
        return try XCTUnwrap(doc.lines.first { $0.kind == .text })
    }

    func testThePrimaryLineIsTheLastOneStarted() {
        let doc = song()
        XCTAssertNil(doc.primaryIndex(at: 0.5))
        XCTAssertEqual(doc.primaryIndex(at: 1.0), 0)
        XCTAssertEqual(doc.primaryIndex(at: 3.2), 0)
        XCTAssertEqual(doc.primaryIndex(at: 3.5), 1)
        XCTAssertEqual(doc.primaryIndex(at: 7.0), 2)
        XCTAssertEqual(doc.primaryIndex(at: 500.0), 3)
    }

    func testTextAtGoesBlankOnceALineHasEnded() {
        let doc = song()
        XCTAssertNil(doc.text(at: 0.5))
        XCTAssertEqual(doc.text(at: 1.0), "one")
        XCTAssertEqual(doc.text(at: 2.9), "one")
        XCTAssertNil(doc.text(at: 3.2))
        XCTAssertEqual(doc.text(at: 4.0), "two")
        XCTAssertNil(doc.text(at: 8.0))
        XCTAssertEqual(doc.text(at: 21.0), "three")
        XCTAssertNil(doc.text(at: 30.0))
    }

    func testOverlappingVoicesAreLitTogether() {
        let doc = LyricsDocument.resolve(
            raw: [raw(1.0, 5.0, "lead"), raw(2.5, 6.5, "echo")], plain: nil, instrumental: false)
        XCTAssertEqual(doc.highlighted(at: 0.5), [])
        XCTAssertEqual(doc.highlighted(at: 2.0), [0])
        XCTAssertEqual(doc.highlighted(at: 3.0), [0, 1])
        XCTAssertEqual(doc.highlighted(at: 5.5), [1])
    }

    func testProgressFollowsTheWords() throws {
        let line = try singingLine()
        XCTAssertEqual(line.progress(at: 9.0), .notStarted)
        XCTAssertEqual(line.progress(at: 10.5), .singing(word: 0, fraction: 0.5))
        XCTAssertEqual(line.progress(at: 12.4), .singing(word: 1, fraction: 1.0))
        XCTAssertEqual(line.progress(at: 13.25), .singing(word: 2, fraction: 0.25))
        XCTAssertEqual(line.progress(at: 14.0), .done)
    }

    func testALineWithoutWordsHasNoProgress() {
        let doc = song()
        XCTAssertNil(doc.lines[1].progress(at: 2.0))
    }

    func testAnInterludeLightsItsBeatsInTurn() throws {
        let doc = song()
        let interlude = try XCTUnwrap(doc.lines.first { $0.isInterlude && $0.start == 6.0 })
        XCTAssertEqual(interlude.end, 20.0)
        XCTAssertEqual(interlude.litBeats(at: 6.0), 0)
        XCTAssertEqual(interlude.litBeats(at: 11.0), 1)
        XCTAssertEqual(interlude.litBeats(at: 16.0), 2)
        XCTAssertEqual(interlude.litBeats(at: 19.99), 2)
        XCTAssertEqual(interlude.litBeats(at: 25.0), 3)
        XCTAssertEqual(interlude.interludeFraction(at: 13.0), 0.5, accuracy: 1e-9)
    }

    func testTheNextBoundaryIsTheSoonestChange() throws {
        let doc = song()
        XCTAssertEqual(doc.nextBoundary(after: 0.0), 1.0)
        XCTAssertEqual(doc.nextBoundary(after: 1.0), 3.0)
        XCTAssertEqual(doc.nextBoundary(after: 3.0), 3.5)
        let beat = try XCTUnwrap(doc.nextBoundary(after: 6.0))
        XCTAssertEqual(beat, 10.666_666_666_666_666, accuracy: 1e-9)
        XCTAssertEqual(doc.nextBoundary(after: 23.9), 24.0)
        XCTAssertNil(doc.nextBoundary(after: 24.0))
    }
}
