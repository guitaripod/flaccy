import XCTest

/// The player's action row reorders on a hold and drag, and the person's
/// arrangement comes back on the next launch.
final class ActionRowUITests: XCTestCase {

    private enum ID {
        static let tabAlbums = "library.tab.albums"
        static let expand = "player.expand"
        static let shuffle = "player.action.shuffle"
        static let queue = "player.queue"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testAHoldAndDragMovesAControlAndTheOrderSurvivesRelaunch() throws {
        let app = openPlayer()
        let shuffle = app.buttons[ID.shuffle]
        let queue = app.buttons[ID.queue]
        XCTAssertTrue(shuffle.waitForExistence(timeout: 10), "Shuffle control is missing")
        XCTAssertTrue(queue.exists, "Queue control is missing")

        let source = shuffle.frame.minX < queue.frame.minX ? shuffle : queue
        let other = source === shuffle ? queue : shuffle
        dragToEnd(source, in: app, holdingFor: 0.8)

        XCTAssertGreaterThan(
            source.frame.minX, 300,
            "The held control did not move to the row's last slot"
        )

        dragToEnd(other, in: app, holdingFor: 0.2)
        XCTAssertGreaterThan(
            other.frame.minX, source.frame.minX,
            "A second drag in the same edit did not move the control"
        )
        let finalX = other.frame.minX

        app.terminate()
        let relaunched = openPlayer()
        let persisted = relaunched.buttons[other.identifier]
        XCTAssertTrue(persisted.waitForExistence(timeout: 10), "The saved control is missing after relaunch")
        XCTAssertEqual(
            persisted.frame.minX, finalX, accuracy: 2,
            "The row did not come back in the saved order"
        )
    }

    @MainActor private func dragToEnd(
        _ control: XCUIElement, in app: XCUIApplication, holdingFor seconds: TimeInterval
    ) {
        let start = control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(
            dx: 0.97, dy: control.frame.midY / app.frame.height
        ))
        start.press(forDuration: seconds, thenDragTo: end)
        sleep(2)
    }

    @MainActor private func openPlayer() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--seed-screenshots")
        app.launch()
        tap(app.tabBars.buttons.element(boundBy: 1), "Library tab", in: app)
        tap(app.buttons[ID.tabAlbums], "Albums segment", in: app)
        tap(app.staticTexts["Parallax Hours"].firstMatch, "album Parallax Hours", in: app)
        tap(app.staticTexts["Slow Machine"].firstMatch, "track Slow Machine", in: app)
        sleep(3)
        tap(app.buttons[ID.expand], "mini player", in: app)
        sleep(3)
        return app
    }

    @MainActor private func tap(_ element: XCUIElement, _ name: String, in app: XCUIApplication) {
        guard element.waitForExistence(timeout: 10) else {
            print("UI BEFORE \(name):\n\(app.debugDescription)")
            XCTFail("\(name) never appeared")
            return
        }
        element.tap()
        sleep(1)
    }
}
