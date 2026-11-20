import XCTest

/// The Now Playing arrangements that only an iPad has: the player as a column
/// beside the library, and the artwork and lyrics sharing the window.
final class PadPlayerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Lyrics fill the page beside the artwork when the player takes the whole
    /// window, and every control on that page still answers touches.
    @MainActor func testFocusedLyricsPageAnswersTouches() throws {
        let app = try launchPad(route: "lyrics")
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 25), "The focused player's transport never appeared")
        pause.tap()
        XCTAssertTrue(
            app.buttons["Play"].waitForExistence(timeout: 5),
            "The transport below the focused lyrics page did not receive the tap"
        )
        let timing = app.buttons["Lyrics timing"]
        XCTAssertTrue(timing.waitForExistence(timeout: 10), "The lyrics controls never appeared")
        timing.tap()
        XCTAssertTrue(
            app.buttons["Show Lyrics Later"].waitForExistence(timeout: 5),
            "A control on the focused lyrics page did not receive the tap"
        )
    }

    /// The player column beside the library draws its action row as round
    /// capsules, splitting into two rows rather than squeezing them into ovals.
    @MainActor func testPlayerColumnDrawsRoundActionControls() throws {
        let app = try launchPad(route: "album")
        let shuffle = app.buttons["player.action.shuffle"]
        XCTAssertTrue(shuffle.waitForExistence(timeout: 25), "The player column never appeared")
        XCTAssertEqual(shuffle.frame.width, 44, accuracy: 0.5, "The action controls are squeezed into ovals")
        XCTAssertEqual(shuffle.frame.height, 44, accuracy: 0.5)
    }

    /// A song in Up Next moves when its grabber is dragged, on the iPad's
    /// queue page where songs dragged in from the library also land.
    @MainActor func testUpNextReordersByItsGrabber() throws {
        let app = try launchPad(route: "queue")
        try assertGrabberDragMovesFirstRow(in: app)
    }

    /// A playlist's songs move by their grabbers in Select, although the
    /// playlist also takes songs dropped on it from the library.
    @MainActor func testPlaylistReordersByItsGrabberInSelect() throws {
        let app = try launchPad(route: "playlist")
        let select = app.buttons["playlist.select"]
        XCTAssertTrue(select.waitForExistence(timeout: 25), "The playlist's Select button never appeared")
        select.tap()
        try assertGrabberDragMovesFirstRow(in: app)
    }

    @MainActor private func assertGrabberDragMovesFirstRow(in app: XCUIApplication) throws {
        let grabbers = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder '"))
        XCTAssertTrue(grabbers.firstMatch.waitForExistence(timeout: 25), "No row listed a grabber")
        let first = grabbers.element(boundBy: 0)
        let movedLabel = first.label
        first.press(forDuration: 0.3, thenDragTo: grabbers.element(boundBy: 3))
        sleep(1)
        let labels = (0..<4).map { grabbers.element(boundBy: $0).label }
        XCTAssertNotEqual(labels.first, movedLabel, "The dragged song stayed first: \(labels)")
        XCTAssertTrue(labels.dropFirst().contains(movedLabel), "The dragged song left the top rows: \(labels)")
    }

    @MainActor private func launchPad(route: String) throws -> XCUIApplication {
        let app = launch(route: route)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "The app's window never appeared")
        try XCTSkipUnless(app.windows.firstMatch.frame.width >= 1000, "These are the iPad's arrangements")
        return app
    }

    @MainActor private func launch(route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-screenshots"]
        app.launchEnvironment = ["FLACCY_ROUTE": route, "FLACCY_PLAYING": "1"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        return app
    }
}
