import XCTest
@testable import flaccy

/// The Library's header leaves with the list and returns on the first move
/// back up, and never hides more than the list has travelled.
nonisolated final class HeaderCollapseTests: XCTestCase {

    func testLeavesWithTheListAndStopsAtItsHeight() {
        var collapse = HeaderCollapse()
        collapse.follow(delta: 40, distanceFromTop: 40, height: 140)
        XCTAssertEqual(collapse.hidden, 40)
        collapse.follow(delta: 400, distanceFromTop: 440, height: 140)
        XCTAssertEqual(collapse.hidden, 140)
    }

    func testReturnsOnTheFirstMoveBackUpFromDeepInTheList() {
        var collapse = HeaderCollapse()
        collapse.follow(delta: 3000, distanceFromTop: 3000, height: 140)
        collapse.follow(delta: -60, distanceFromTop: 2940, height: 140)
        XCTAssertEqual(collapse.hidden, 80)
        collapse.follow(delta: -500, distanceFromTop: 2440, height: 140)
        XCTAssertEqual(collapse.hidden, 0)
    }

    func testNeverHidesMoreThanTheListHasTravelled() {
        var collapse = HeaderCollapse()
        collapse.follow(delta: 90, distanceFromTop: 30, height: 140)
        XCTAssertEqual(collapse.hidden, 30)
        collapse.follow(delta: 10, distanceFromTop: -20, height: 140)
        XCTAssertEqual(collapse.hidden, 0)
    }

    func testSettlesTheWayTheListLastMoved() {
        var collapse = HeaderCollapse()
        collapse.follow(delta: 50, distanceFromTop: 600, height: 140)
        collapse.settle(distanceFromTop: 600, height: 140)
        XCTAssertEqual(collapse.hidden, 140)

        collapse.follow(delta: -30, distanceFromTop: 570, height: 140)
        XCTAssertEqual(collapse.hidden, 110)
        collapse.settle(distanceFromTop: 570, height: 140)
        XCTAssertEqual(collapse.hidden, 0)
    }

    func testSettlesOpenNearTheTopWhereTheListCannotCoverTheGap() {
        var collapse = HeaderCollapse()
        collapse.follow(delta: 100, distanceFromTop: 100, height: 140)
        collapse.settle(distanceFromTop: 100, height: 140)
        XCTAssertEqual(collapse.hidden, 0)
    }

    func testAHeaderThatShrinksKeepsNoMoreHiddenThanItsNewHeight() {
        var collapse = HeaderCollapse()
        collapse.follow(delta: 140, distanceFromTop: 900, height: 140)
        collapse.follow(delta: 0, distanceFromTop: 900, height: 96)
        XCTAssertEqual(collapse.hidden, 96)
    }
}
