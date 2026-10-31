import XCTest
@testable import FlaccyCore

final class LiveListingPaceTests: XCTestCase {

    private let start = ContinuousClock.now

    func testNothingIsListedInTheFirstSeconds() {
        let pace = LiveListingPace(began: start)
        XCTAssertFalse(pace.isDue(at: start))
        XCTAssertFalse(pace.isDue(at: start + .milliseconds(2_999)))
    }

    func testTheFirstListingComesOnceItsDelayHasPassed() {
        let pace = LiveListingPace(began: start)
        XCTAssertTrue(pace.isDue(at: start + .seconds(3)))
        XCTAssertTrue(pace.isDue(at: start + .seconds(40)))
    }

    func testLaterListingsWaitTheirSpacing() {
        var pace = LiveListingPace(began: start)
        let first = start + .seconds(4)
        pace.noteListed(at: first)
        XCTAssertFalse(pace.isDue(at: first))
        XCTAssertFalse(pace.isDue(at: first + .milliseconds(4_999)))
        XCTAssertTrue(pace.isDue(at: first + .seconds(5)))
    }

    func testTheSpacingCountsFromTheLatestListing() {
        var pace = LiveListingPace(began: start)
        pace.noteListed(at: start + .seconds(3))
        pace.noteListed(at: start + .seconds(9))
        XCTAssertFalse(pace.isDue(at: start + .seconds(13)))
        XCTAssertTrue(pace.isDue(at: start + .seconds(14)))
    }
}
