import XCTest
@testable import FlaccyCore

final class PeriodDeltaTests: XCTestCase {

    func testD1RisePercentRoundsToNearest() {
        XCTAssertEqual(PeriodDelta.compare(current: 56, previous: 50), .up(12))
    }

    func testD2FallPercentRoundsAwayFromZero() {
        XCTAssertEqual(PeriodDelta.compare(current: 50, previous: 56), .down(11))
    }

    func testD3AnythingAgainstNothingIsNew() {
        XCTAssertEqual(PeriodDelta.compare(current: 5, previous: 0), .new)
    }

    func testD4NothingAgainstNothingShowsNoChip() {
        XCTAssertEqual(PeriodDelta.compare(current: 0, previous: 0), PeriodDelta.none)
    }

    func testD5EqualIsEven() {
        XCTAssertEqual(PeriodDelta.compare(current: 7, previous: 7), .even)
    }

    func testD6ChangeThatRoundsToZeroIsEven() {
        XCTAssertEqual(PeriodDelta.compare(current: 1001, previous: 1000), .even)
    }

    func testD7RiseIsCappedAtNineHundredNinetyNine() {
        XCTAssertEqual(PeriodDelta.compare(current: 4000, previous: 100), .up(999))
    }

    func testD8TotalLossIsAHundredPercent() {
        XCTAssertEqual(PeriodDelta.compare(current: 0, previous: 10), .down(100))
    }
}
