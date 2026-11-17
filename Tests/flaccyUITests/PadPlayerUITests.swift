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
