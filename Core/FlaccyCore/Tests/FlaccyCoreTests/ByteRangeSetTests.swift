import Foundation
import XCTest
@testable import FlaccyCore

/// Mirrored by the tests in `linux/shared/src/remote/byte_range_set.rs`: the same ranges and outcomes.
final class ByteRangeSetTests: XCTestCase {

    private func set(_ ranges: Range<Int64>...) -> ByteRangeSet {
        var result = ByteRangeSet()
        for range in ranges {
            result.insert(range)
        }
        return result
    }

    func testMissingReturnsTheGapsInsideTheRange() {
        let ranges = set(0..<10, 20..<30)

        XCTAssertEqual(ranges.missing(in: 0..<40), [10..<20, 30..<40])
    }

    func testInsertingTheGapMergesNeighboursIntoOneRange() {
        var ranges = set(0..<10, 20..<30)

        ranges.insert(10..<20)

        XCTAssertEqual(ranges.ranges, [0..<30])
    }

    func testOverlappingInsertMergesEveryRangeItTouches() {
        var ranges = set(0..<10, 20..<30)

        ranges.insert(5..<25)

        XCTAssertEqual(ranges.ranges, [0..<30])
    }

    func testEmptyInsertIsANoOp() {
        var ranges = set(0..<10)

        ranges.insert(5..<5)

        XCTAssertEqual(ranges.ranges, [0..<10])
    }

    func testContainsBeforeAndAfterTheMerge() {
        var ranges = set(0..<10, 20..<30)

        XCTAssertTrue(ranges.contains(2..<8))
        XCTAssertFalse(ranges.contains(8..<12))

        ranges.insert(10..<20)
        XCTAssertTrue(ranges.contains(8..<12))
    }

    func testCompletenessNeedsOneRangeCoveringTheWholeFile() {
        var ranges = set(0..<10, 20..<30)
        ranges.insert(10..<20)

        XCTAssertTrue(ranges.isComplete(fileSize: 30))
        XCTAssertFalse(ranges.isComplete(fileSize: 31))
    }

    func testCoveredBytesCountsEveryRange() {
        XCTAssertEqual(set(0..<10, 20..<30).coveredBytes, 20)
        XCTAssertEqual(ByteRangeSet().coveredBytes, 0)
    }

    func testJSONIsAnArrayOfStartEndPairs() throws {
        let ranges = set(0..<30)

        let data = try JSONEncoder().encode(ranges)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[[0,30]]")
        XCTAssertEqual(try JSONDecoder().decode(ByteRangeSet.self, from: data), ranges)
    }

    func testDecodingMergesAndRejectsInvalidPairs() throws {
        let merged = try JSONDecoder().decode(ByteRangeSet.self, from: Data("[[0,10],[10,20]]".utf8))

        XCTAssertEqual(merged.ranges, [0..<20])
        XCTAssertThrowsError(try JSONDecoder().decode(ByteRangeSet.self, from: Data("[[20,10]]".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(ByteRangeSet.self, from: Data("[[1,2,3]]".utf8)))
    }
}
