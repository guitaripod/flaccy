import XCTest
@testable import FlaccyCore

final class LyricsLyricsfileTests: XCTestCase {

    private static let wordSynced = "version: '1.0'\n\nmetadata:\n  title: 'Small Hours'\n  artist: 'Example Artist'\n  language: 'en'\n\nlines:\n  - text: 'Stay until the morning'\n    start_ms: 4200\n    end_ms: 6800\n    words:\n      - text: 'Stay '\n        start_ms: 4200\n        end_ms: 4800\n      - text: 'until '\n        start_ms: 4800\n        end_ms: 5400\n      - text: 'the '\n        start_ms: 5400\n        end_ms: 5750\n      - text: 'morning'\n        start_ms: 5750\n        end_ms: 6800\n\nplain: |\n  Stay until the morning\n"

    private static let overlapping = "version: '1.0'\n\nmetadata:\n  title: 'Two Voices'\n  artist: 'Example Duo'\n\nlines:\n  - text: 'I will follow the river'\n    start_ms: 10000\n    end_ms: 15000\n  - text: 'Follow the river home'\n    start_ms: 12500\n    end_ms: 16500\n\nplain: |\n  I will follow the river\n  Follow the river home\n"

    private static let instrumental = "version: '1.0'\n\nmetadata:\n  title: 'Quiet Transit'\n  artist: 'Example Ensemble'\n  duration_ms: 240000\n  instrumental: true\n"

    private static let minimal = "version: '1.0'\n\nmetadata:\n  title: 'Morning Light'\n  artist: 'Example Artist'\n\nplain: |\n  Morning light through the window\n  A new day begins\n"

    private static let lrclib = "version: '1.0'\nmetadata:\n  title: Blinding Lights\n  artist: The Weeknd\n  album: After Hours\n  duration_ms: 200000\n  instrumental: false\nlines:\n- text: Yeah\n  start_ms: 13130\n  end_ms: 16560\n- text: ♪\n  start_ms: 16560\n  end_ms: 27160\n- text: I've been tryna call\n  start_ms: 27160\n  end_ms: 29960\n- text:\n  start_ms: 29960\n  end_ms: 30000\n- text: 'Don''t stop'\n  start_ms: 30000\n  end_ms: 32000\n  words:\n  - text: 'Don''t '\n    start_ms: 30000\n    end_ms: 31000\n  - text: \"stop\\u0021\"\n    start_ms: 31000\n    end_ms: 32000\n"

    private func textLines(_ doc: LyricsDocument) -> [LyricsLine] {
        doc.lines.filter { $0.kind == .text }
    }

    func testReadsTheWordSyncedExample() throws {
        let doc = try XCTUnwrap(LyricsParser.parseLyricsfile(Self.wordSynced))
        let lines = textLines(doc)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Stay until the morning")
        XCTAssertEqual(lines[0].start, 4.2)
        XCTAssertEqual(lines[0].end, 6.8)
        let expected: [(Double, Double, String)] = [
            (4.2, 4.8, "Stay "),
            (4.8, 5.4, "until "),
            (5.4, 5.75, "the "),
            (5.75, 6.8, "morning"),
        ]
        XCTAssertEqual(lines[0].words.count, expected.count)
        for (word, want) in zip(lines[0].words, expected) {
            XCTAssertEqual(word.start, want.0)
            XCTAssertEqual(word.end, want.1)
            XCTAssertEqual(word.text, want.2)
        }
        XCTAssertEqual(doc.plain, "Stay until the morning\n")
        XCTAssertTrue(doc.hasWordSync)
    }

    func testKeepsOverlappingLinesOverlapping() throws {
        let doc = try XCTUnwrap(LyricsParser.parseLyricsfile(Self.overlapping))
        let lines = textLines(doc)
        XCTAssertEqual(lines[0].start, 10.0)
        XCTAssertEqual(lines[0].end, 15.0)
        XCTAssertEqual(lines[1].start, 12.5)
        XCTAssertEqual(lines[1].end, 16.5)
    }

    func testAnInstrumentalFileHasNoLines() throws {
        let doc = try XCTUnwrap(LyricsParser.parseLyricsfile(Self.instrumental))
        XCTAssertTrue(doc.instrumental)
        XCTAssertTrue(doc.lines.isEmpty)
    }

    func testAPlainOnlyFileHasTextAndNoLines() throws {
        let doc = try XCTUnwrap(LyricsParser.parseLyricsfile(Self.minimal))
        XCTAssertFalse(doc.hasSynced)
        XCTAssertEqual(doc.plain, "Morning light through the window\nA new day begins\n")
    }

    func testReadsWhatLrclibActuallyServes() throws {
        let doc = try XCTUnwrap(LyricsParser.parseLyricsfile(Self.lrclib))
        let lines = textLines(doc)
        XCTAssertEqual(lines.map(\.text), ["Yeah", "I've been tryna call", "Don't stop!"])
        XCTAssertEqual(lines[2].words.count, 2)
        XCTAssertEqual(lines[2].words[1].text, "stop!")
        XCTAssertEqual(lines[0].end, 16.56)
    }

    func testALongQuotedLineFoldedAcrossLinesIsJoined() throws {
        let text = "version: '1.0'\nmetadata:\n  title: t\n  artist: a\nlines:\n- text: 'one two\n    three'\n  start_ms: 1000\n"
        let doc = try XCTUnwrap(LyricsParser.parseLyricsfile(text))
        XCTAssertEqual(textLines(doc)[0].text, "one two three")
    }

    func testRefusesWhatTheFormatForbids() {
        let header = "version: '1.0'\nmetadata:\n  title: t\n  artist: a\n"
        XCTAssertNil(LyricsParser.parseLyricsfile("version: '2.0'\nmetadata:\n  title: t\n  artist: a\n"))
        XCTAssertNil(LyricsParser.parseLyricsfile(header + "version: '1.0'\n"))
        XCTAssertNil(LyricsParser.parseLyricsfile(header + "lines:\n\t- text: x\n"))
        XCTAssertNil(LyricsParser.parseLyricsfile(header + "plain: &a x\n"))
        XCTAssertNil(LyricsParser.parseLyricsfile(header + "lines:\n- text: 'open\n  start_ms: 1\n"))
        XCTAssertNil(LyricsParser.parseLyricsfile(header + "lines:\n- text: x\n  start_ms: -5\n"))
        XCTAssertNil(LyricsParser.parseLyricsfile(header + "lines:\n- text: x\n"))
        XCTAssertNil(LyricsParser.parseLyricsfile("not yaml at all"))
        XCTAssertNil(LyricsParser.parseLyricsfile(""))
    }

    func testScalarsAreTypedTheWayYamlTypesThem() {
        XCTAssertEqual(LyricsLyricsfile.plainScalar("42"), .int(42))
        XCTAssertEqual(LyricsLyricsfile.plainScalar("-7"), .int(-7))
        XCTAssertEqual(LyricsLyricsfile.plainScalar("true"), .bool(true))
        XCTAssertEqual(LyricsLyricsfile.plainScalar("~"), .null)
        XCTAssertEqual(LyricsLyricsfile.plainScalar("1.0"), .str("1.0"))
        XCTAssertEqual(LyricsLyricsfile.plainScalar("a # note"), .str("a"))
        XCTAssertEqual(LyricsLyricsfile.plainScalar("a#b"), .str("a#b"))
    }

    func testWindowsLineEndingsAndCombiningMarksSurviveTheReader() throws {
        let text = "version: '1.0'\r\nmetadata:\r\n  title: t\r\nlines:\r\n- text: \"e\\u0301t\\u00e9 \\\"q\\\"\"\r\n  start_ms: 2000\r\n"
        let doc = try XCTUnwrap(LyricsParser.parseLyricsfile(text))
        XCTAssertEqual(textLines(doc)[0].text, "e\u{301}t\u{e9} \"q\"")
    }

    func testABlockScalarKeepsItsLineBreaksAndAFoldedOneJoinsThem() throws {
        let header = "version: '1.0'\nmetadata:\n  title: t\n"
        let literal = try XCTUnwrap(LyricsParser.parseLyricsfile(header + "plain: |-\n  a\n  b\n"))
        XCTAssertEqual(literal.plain, "a\nb")
        let folded = try XCTUnwrap(LyricsParser.parseLyricsfile(header + "plain: >\n  a\n  b\n"))
        XCTAssertEqual(folded.plain, "a b\n")
    }
}
