import XCTest

/// The 2.0 showcase leads each person the right way on: an ended trial to the plans, a running one to the music.
/// The trial day is the debug clock's, so a device's real purchase state is never touched.
final class ShowcaseUITests: XCTestCase {

    private enum ID {
        static let primary = "showcase.continue"
        static let secondary = "showcase.secondary"
        static let everything = "showcase.everything"
        static let purchase = "paywall.purchase"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testAnEndedTrialGoesFromTheShowcaseToThePlans() throws {
        let app = launch(trialDay: 9)
        let primary = app.buttons[ID.primary]
        XCTAssertTrue(primary.waitForExistence(timeout: 20), "The showcase did not open")
        XCTAssertTrue(waitUntilEnabled(primary), "The main button never became usable")
        XCTAssertTrue(app.buttons[ID.secondary].exists, "An ended trial has no way to say not now")
        primary.tap()
        XCTAssertTrue(app.buttons[ID.purchase].waitForExistence(timeout: 15), "See Plans did not open the plans")
    }

    @MainActor func testNotNowClosesTheShowcaseWithoutThePlans() throws {
        let app = launch(trialDay: 9)
        let secondary = app.buttons[ID.secondary]
        XCTAssertTrue(secondary.waitForExistence(timeout: 20), "The showcase did not open")
        XCTAssertTrue(waitUntilEnabled(secondary), "Not Now never became usable")
        secondary.tap()
        XCTAssertTrue(waitUntilGone(app.buttons[ID.primary]), "Not Now left the showcase open")
        XCTAssertFalse(app.buttons[ID.purchase].exists, "Not Now opened the plans")
    }

    @MainActor func testARunningTrialListensFirstAndReachesThePlansFromTheSecondButton() throws {
        let app = launch(trialDay: 3)
        let secondary = app.buttons[ID.secondary]
        XCTAssertTrue(secondary.waitForExistence(timeout: 20), "A running trial has no way to the plans")
        XCTAssertTrue(waitUntilEnabled(secondary), "See Plans never became usable")
        XCTAssertTrue(app.buttons[ID.everything].isEnabled)
        secondary.tap()
        XCTAssertTrue(app.buttons[ID.purchase].waitForExistence(timeout: 15), "See Plans did not open the plans")
    }

    @MainActor private func launch(trialDay: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--show-showcase", "--trial-day", "\(trialDay)", "--unpaid"]
        #if targetEnvironment(simulator)
        app.launchArguments.append("--seed-screenshots")
        #endif
        app.launch()
        return app
    }

    @MainActor private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 6) -> Bool {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        return XCTWaiter().wait(for: [enabled], timeout: timeout) == .completed
    }

    @MainActor private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 6) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
