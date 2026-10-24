import XCTest
@testable import FlaccyCore

final class LyricsParserTests: XCTestCase {

    private func texts(_ doc: LyricsDocument) -> [(Double, String)] {
        doc.lines.filter { $0.kind == .text }.map { ($0.start, $0.text) }
    }

    private func assertTexts(
        _ doc: LyricsDocument, _ expected: [(Double, String)],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let actual = texts(doc)
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (left, right) in zip(actual, expected) {
            XCTAssertEqual(left.0, right.0, file: file, line: line)
            XCTAssertEqual(left.1, right.1, file: file, line: line)
        }
    }

    func testParsesEveryTimestampShape() {
        XCTAssertEqual(LyricsParser.parseTimestamp("01:30"), 90.0)
        XCTAssertEqual(LyricsParser.parseTimestamp("01:30.50"), 90.5)
        XCTAssertEqual(LyricsParser.parseTimestamp("01:30:50"), 90.5)
        XCTAssertEqual(LyricsParser.parseTimestamp("01:02:03.5"), 3723.5)
        XCTAssertEqual(LyricsParser.parseTimestamp("01:30,5"), 90.5)
        XCTAssertNil(LyricsParser.parseTimestamp("ti"))
        XCTAssertNil(LyricsParser.parseTimestamp("ar:Artist"))
    }

    func testRepeatedStampsExpandToOneLineEach() {
        let doc = LyricsParser.parseLRC("[00:10.00][01:10.00]Chorus")
        assertTexts(doc, [(10.0, "Chorus"), (70.0, "Chorus")])
    }

    func testMetadataTagsAreNotLines() {
        let doc = LyricsParser.parseLRC("[ar:Someone]\n[ti:Song]\n[offset:+250]\n[00:05.00]Hello")
        assertTexts(doc, [(5.0, "Hello")])
    }

    func testAByteOrderMarkDoesNotHideTheFirstLine() {
        let doc = LyricsParser.parseLRC("\u{feff}[00:05.00]Hello")
        assertTexts(doc, [(5.0, "Hello")])
    }

    func testEnhancedWordTagsBecomeTimedWords() throws {
        let doc = LyricsParser.parseLRC("[00:12.00]<00:12.00>Hello <00:12.50>world<00:13.00>\n[00:20.00]x")
        let line = try XCTUnwrap(doc.lines.first { $0.kind == .text })
        XCTAssertEqual(line.text, "Hello world")
        XCTAssertEqual(line.words.count, 2)
        XCTAssertEqual(line.words[0].start, 12.0)
        XCTAssertEqual(line.words[0].end, 12.5)
        XCTAssertEqual(line.words[0].text, "Hello ")
        XCTAssertEqual(line.words[1].start, 12.5)
        XCTAssertEqual(line.words[1].end, 13.0)
        XCTAssertEqual(line.words[1].text, "world")
    }

    func testTextBeforeTheFirstWordTagStartsWithTheLine() throws {
        let doc = LyricsParser.parseLRC("[00:12.00]Oh <00:12.50>yes")
        let line = try XCTUnwrap(doc.lines.first { $0.kind == .text })
        XCTAssertEqual(line.text, "Oh yes")
        XCTAssertEqual(line.words[0].start, 12.0)
        XCTAssertEqual(line.words[0].end, 12.5)
    }

    func testALineWithOnlyWordTagsTakesItsStartFromTheFirst() throws {
        let doc = LyricsParser.parseLRC("<00:08.00>Hi <00:08.40>there")
        let line = try XCTUnwrap(doc.lines.first { $0.kind == .text })
        XCTAssertEqual(line.start, 8.0)
        XCTAssertEqual(line.text, "Hi there")
    }

    func testAngleBracketsThatAreNotTimestampsStayInTheText() {
        let doc = LyricsParser.parseLRC("[00:05.00]I <3 you <i>so</i>")
        assertTexts(doc, [(5.0, "I <3 you <i>so</i>")])
    }

    func testASecondStampShiftsTheWordsWithIt() {
        let doc = LyricsParser.parseLRC("[00:10.00][00:30.00]<00:10.00>a <00:11.00>b")
        let lines = doc.lines.filter { $0.kind == .text }
        XCTAssertEqual(lines[1].start, 30.0)
        XCTAssertEqual(lines[1].words[1].start, 31.0)
    }

    func testLinesAreOrderedByTime() {
        let doc = LyricsParser.parseLRC("[00:20.00]b\n[00:05.00]a")
        let found = texts(doc)
        XCTAssertEqual(found[0].1, "a")
        XCTAssertEqual(found[1].1, "b")
    }

    func testWindowsLineEndingsAndCombiningMarksDoNotBreakTheScan() {
        let doc = LyricsParser.parseLRC("[00:05.00]Caf\u{e9}\r\n[00:07.00]e\u{301}t\u{e9}\r\n")
        assertTexts(doc, [(5.0, "Caf\u{e9}"), (7.0, "e\u{301}t\u{e9}")])
    }

    func testTimestampsRejectWhatRustRejects() {
        XCTAssertNil(LyricsParser.parseTimestamp("0x10:00"))
        XCTAssertNil(LyricsParser.parseTimestamp("nan:00"))
        XCTAssertNil(LyricsParser.parseTimestamp("inf:00"))
        XCTAssertNil(LyricsParser.parseTimestamp("1:2:3:4"))
        XCTAssertNil(LyricsParser.parseTimestamp("-1:00"))
        XCTAssertNil(LyricsParser.parseTimestamp(""))
    }
}
