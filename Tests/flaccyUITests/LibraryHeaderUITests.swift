import XCTest

/// The Library's picker and chips scroll away with the list and return on the
/// first move back up. On a simulator the fictional library is seeded; on a
/// device the test scrolls whatever library is there, which must fill more
/// than two screens.
final class LibraryHeaderUITests: XCTestCase {

    private enum ID {
        static let tabAlbums = "library.tab.albums"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testTheHeaderLeavesWithTheListAndReturnsOnTheWayBackUp() throws {
        let app = XCUIApplication()
        #if targetEnvironment(simulator)
        app.launchArguments = ["--seed-screenshots"]
        app.launchEnvironment["FLACCY_ROUTE"] = "library"
        #endif
        app.launch()

        let picker = app.buttons[ID.tabAlbums]
        if !picker.waitForExistence(timeout: 8) {
            app.tabBars.buttons.element(boundBy: 1).tap()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "The Library's picker is missing")
        XCTAssertTrue(picker.isHittable, "The picker is not on screen with the list at its top")
        attach(app, named: "rest")

        let list = app.collectionViews.firstMatch
        list.swipeUp()
        list.swipeUp()
        sleep(1)
        XCTAssertFalse(picker.isHittable, "The header stayed on screen after the list scrolled down")
        attach(app, named: "scrolled")

        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
        from.press(forDuration: 0.05, thenDragTo: to)
        sleep(1)
        XCTAssertTrue(picker.isHittable, "The header did not return on a move back up")
        attach(app, named: "returned")
    }

    @MainActor private func attach(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
