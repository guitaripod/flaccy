import XCTest
@testable import FlaccyCore

final class LyricsDocumentTests: XCTestCase {

    private func raw(_ start: Double, _ end: Double?, _ text: String) -> LyricsRawLine {
        LyricsRawLine(start: start, end: end, text: text, words: [])
    }

    func testAnUnmarkedLineRunsToTheNextOne() {
        let doc = LyricsDocument.resolve(
            raw: [raw(1.0, nil, "a"), raw(4.0, nil, "b")], plain: nil, instrumental: false)
        XCTAssertEqual(doc.lines.map(\.end), [4.0, 14.0])
        XCTAssertEqual(doc.lines[0].kind, .text)
    }

    func testABlankStampEndsTheLineBeforeIt() {
        let doc = LyricsDocument.resolve(
            raw: [raw(1.0, nil, "a"), raw(3.0, nil, ""), raw(20.0, nil, "b")],
            plain: nil, instrumental: false)
        XCTAssertEqual(doc.lines[0].end, 3.0)
    }

    func testALineOfMusicNotesIsABreakNotALyric() {
        let doc = LyricsDocument.resolve(
            raw: [raw(1.0, 3.0, "a"), raw(3.0, 14.0, "\u{266A}"), raw(14.0, 16.0, "b")],
            plain: nil, instrumental: false)
        XCTAssertEqual(doc.lines.map(\.kind), [.text, .interlude, .text])
        XCTAssertEqual(doc.lines[1].start, 3.0)
        XCTAssertEqual(doc.lines[1].end, 14.0)
    }

    func testALongGapBecomesAnInterludeAndTheIntroToo() {
        let doc = LyricsDocument.resolve(
            raw: [raw(6.0, 8.0, "a"), raw(20.0, 22.0, "b")], plain: nil, instrumental: false)
        XCTAssertEqual(doc.lines.map(\.kind), [.interlude, .text, .interlude, .text])
        XCTAssertEqual(doc.lines[0].start, 0.0)
        XCTAssertEqual(doc.lines[0].end, 6.0)
        XCTAssertEqual(doc.lines[2].start, 8.0)
        XCTAssertEqual(doc.lines[2].end, 20.0)
    }

    func testAShortGapIsNotAnInterlude() {
        let doc = LyricsDocument.resolve(
            raw: [raw(1.0, 3.0, "a"), raw(5.0, 7.0, "b")], plain: nil, instrumental: false)
        XCTAssertEqual(doc.lines.count, 2)
    }

    func testOverlappingLinesLeaveNoInterludeBetweenThem() {
        let doc = LyricsDocument.resolve(
            raw: [raw(10.0, 15.0, "a"), raw(12.5, 16.5, "b")], plain: nil, instrumental: false)
        XCTAssertEqual(doc.lines.map(\.kind), [.interlude, .text, .text])
    }

    func testLinesStampedTogetherShareOneEnd() {
        let doc = LyricsDocument.resolve(
            raw: [raw(1.0, nil, "a"), raw(1.0, nil, "b"), raw(4.0, nil, "c")],
            plain: nil, instrumental: false)
        XCTAssertEqual(doc.lines[0].end, 4.0)
        XCTAssertEqual(doc.lines[1].end, 4.0)
    }

    func testParenthesesAroundTheWholeLineMarkBackingVocals() {
        XCTAssertTrue(LyricsDocument.isBackground("(oh oh oh)"))
        XCTAssertTrue(LyricsDocument.isBackground(" (a (b) c) "))
        XCTAssertFalse(LyricsDocument.isBackground("(a) b (c)"))
        XCTAssertFalse(LyricsDocument.isBackground("plain"))
    }

    func testWordsGetEndsAndTheLineTextFollowsThem() throws {
        let line = LyricsRawLine(
            start: 1.0, end: 4.0, text: "ignored",
            words: [
                LyricsRawWord(start: 1.0, end: nil, text: " Hello "),
                LyricsRawWord(start: 2.0, end: 2.5, text: "big "),
                LyricsRawWord(start: 3.0, end: nil, text: "world "),
            ])
        let doc = LyricsDocument.resolve(raw: [line], plain: nil, instrumental: false)
        let text = try XCTUnwrap(doc.lines.first { !$0.isInterlude })
        XCTAssertEqual(text.text, "Hello big world")
        XCTAssertEqual(text.words.map(\.end), [2.0, 2.5, 4.0])
    }

    func testALineEndsWithItsLastTimedWordWhenNothingSaysOtherwise() {
        let line = LyricsRawLine(
            start: 1.0, end: nil, text: "",
            words: [
                LyricsRawWord(start: 1.0, end: 1.5, text: "Hi "),
                LyricsRawWord(start: 1.5, end: 2.25, text: "there"),
            ])
        let doc = LyricsDocument.resolve(
            raw: [line, raw(9.0, nil, "later")], plain: nil, instrumental: false)
        XCTAssertEqual(doc.lines[0].end, 2.25)
        XCTAssertEqual(doc.lines[1].kind, .interlude)
        XCTAssertEqual(doc.lines[1].start, 2.25)
        XCTAssertEqual(doc.lines[1].end, 9.0)
    }

    func testAWhitespaceFragmentJoinsTheWordBeforeIt() {
        let line = LyricsRawLine(
            start: 0.0, end: 2.0, text: "",
            words: [
                LyricsRawWord(start: 0.0, end: nil, text: "a"),
                LyricsRawWord(start: 0.5, end: nil, text: " "),
                LyricsRawWord(start: 1.0, end: nil, text: "b"),
            ])
        let doc = LyricsDocument.resolve(raw: [line], plain: nil, instrumental: false)
        XCTAssertEqual(doc.lines[0].text, "a b")
        XCTAssertEqual(doc.lines[0].words.count, 2)
    }

    func testLinesWithEqualStartsKeepTheirOriginalOrder() {
        let doc = LyricsDocument.resolve(
            raw: [raw(5.0, 6.0, "first"), raw(2.0, 3.0, "early"), raw(5.0, 6.0, "second")],
            plain: nil, instrumental: false)
        XCTAssertEqual(doc.lines.filter { !$0.isInterlude }.map(\.text), ["early", "first", "second"])
    }

    func testNonFiniteAndNegativeStartsAreDroppedAndBlankPlainIsNil() {
        let doc = LyricsDocument.resolve(
            raw: [raw(-1.0, nil, "a"), raw(.nan, nil, "b"), raw(.infinity, nil, "c")],
            plain: "  \n ", instrumental: false)
        XCTAssertTrue(doc.lines.isEmpty)
        XCTAssertNil(doc.plain)
        XCTAssertTrue(doc.isEmpty)
    }
}
