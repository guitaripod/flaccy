import XCTest
@testable import FlaccyCore

final class LyricsTimingNoteTests: XCTestCase {

    private func raw(_ start: Double, _ text: String, words: [LyricsRawWord] = []) -> LyricsRawLine {
        LyricsRawLine(start: start, end: nil, text: text, words: words)
    }

    private func timed(_ start: Double, _ text: String) -> LyricsRawLine {
        raw(start, text, words: [LyricsRawWord(start: start, end: start + 0.5, text: text)])
    }

    private func interlude(_ start: Double, _ end: Double) -> LyricsLine {
        LyricsLine(start: start, end: end, text: "", words: [], kind: .interlude, background: false)
    }

    func testAWordTimedDocumentHasNoNote() {
        let document = LyricsDocument.resolve(raw: [timed(1, "Hello"), timed(3, "Again")])
        XCTAssertTrue(document.hasWordSync)
        XCTAssertNil(LyricsTimingNote.kind(for: document))
    }

    func testOneTimedLineAmongPlainLinesHasNoNote() {
        let document = LyricsDocument.resolve(raw: [raw(1, "Hello world"), timed(3, "Again"), raw(5, "Last line")])
        XCTAssertTrue(document.hasWordSync)
        XCTAssertNil(LyricsTimingNote.kind(for: document))
    }

    func testALineTimedDocumentIsLineByLine() {
        let document = LyricsDocument.resolve(raw: [raw(1, "Hello world"), raw(3, "Again")])
        XCTAssertEqual(LyricsTimingNote.kind(for: document), .lineByLine)
    }

    func testInterludesAloneDoNotCountAsSyncedLines() {
        let document = LyricsDocument(
            lines: [interlude(0, 8), interlude(20, 30)], plain: "Hello world", instrumental: false)
        XCTAssertEqual(LyricsTimingNote.kind(for: document), .unsynced)
    }

    func testADocumentWithPlainTextOnlyIsUnsynced() {
        let document = LyricsDocument.resolve(raw: [], plain: "Hello world", instrumental: false)
        XCTAssertEqual(LyricsTimingNote.kind(for: document), .unsynced)
    }

    func testLinesAndPlainTextTogetherAreLineByLine() {
        let document = LyricsDocument.resolve(raw: [raw(1, "Hello world")], plain: "Hello world", instrumental: false)
        XCTAssertEqual(LyricsTimingNote.kind(for: document), .lineByLine)
    }

    func testAnInstrumentalTrackHasNoNote() {
        XCTAssertNil(LyricsTimingNote.kind(for: LyricsDocument.resolve(raw: [], plain: nil, instrumental: true)))
        XCTAssertNil(LyricsTimingNote.kind(for: LyricsDocument.resolve(raw: [], plain: "Hello", instrumental: true)))
    }

    func testAnEmptyDocumentHasNoNote() {
        XCTAssertNil(LyricsTimingNote.kind(for: LyricsDocument()))
        XCTAssertNil(LyricsTimingNote.kind(for: LyricsDocument.resolve(raw: [], plain: "  \n", instrumental: false)))
    }
}
