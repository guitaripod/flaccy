import XCTest
@testable import FlaccyCore

final class TrackNumberTagTests: XCTestCase {

    func testTextWithTotalNamesThePosition() {
        XCTAssertEqual(TrackNumberTag.number(fromText: "7/12"), 7)
        XCTAssertEqual(TrackNumberTag.number(fromText: " 07 / 12 "), 7)
    }

    func testPlainTextNamesThePosition() {
        XCTAssertEqual(TrackNumberTag.number(fromText: "3"), 3)
        XCTAssertEqual(TrackNumberTag.number(fromText: "112"), 112)
    }

    func testTextWithoutAPositionIsZero() {
        XCTAssertEqual(TrackNumberTag.number(fromText: ""), 0)
        XCTAssertEqual(TrackNumberTag.number(fromText: "/12"), 0)
        XCTAssertEqual(TrackNumberTag.number(fromText: "A1"), 0)
        XCTAssertEqual(TrackNumberTag.number(fromText: "0"), 0)
        XCTAssertEqual(TrackNumberTag.number(fromText: "-4"), 0)
    }

    func testMP4PairNamesThePosition() {
        XCTAssertEqual(TrackNumberTag.number(fromMP4Pair: Data([0, 0, 0, 7, 0, 12, 0, 0])), 7)
        XCTAssertEqual(TrackNumberTag.number(fromMP4Pair: Data([0, 0, 1, 2, 0, 0])), 258)
    }

    func testShortMP4PairIsZero() {
        XCTAssertEqual(TrackNumberTag.number(fromMP4Pair: Data()), 0)
        XCTAssertEqual(TrackNumberTag.number(fromMP4Pair: Data([0, 0, 7])), 0)
    }
}
