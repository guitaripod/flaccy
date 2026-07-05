import XCTest

final class ScreenshotTests: XCTestCase {

    private let outputDirectory = "/tmp/flaccy-shots/raw"

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testDarkTour() throws {
        let app = launchApp()
        capture(app, wait: 8, name: "dark-01-library-grid")

        app.buttons["Songs"].firstMatch.tap()
        capture(app, wait: 6, name: "dark-02-library-songs")

        app.buttons["Albums"].firstMatch.tap()
        sleep(2)
        openAlbum(app, named: "Lateralus")
        capture(app, wait: 6, name: "dark-03-album-detail")

        startPlayback(app, trackNamed: "Schism")
        expandNowPlaying(app)
        capture(app, wait: 6, name: "dark-04-now-playing")

        tapIfExists(app.buttons["Lyrics"], in: app)
        capture(app, wait: 12, name: "dark-05-lyrics")
        tapIfExists(app.buttons["Lyrics"], in: app)
        sleep(1)

        tapIfExists(app.buttons["Queue"], in: app)
        capture(app, wait: 3, name: "dark-06-queue")
        dismissSheet(app)

        collapseNowPlaying(app)
        popToRoot(app)

        app.buttons["Playlists"].firstMatch.tap()
        sleep(2)
        tapIfExists(app.staticTexts["Recap"], in: app)
        capture(app, wait: 8, name: "dark-07-recap-charts")
        app.swipeUp(); app.swipeUp()
        capture(app, wait: 2, name: "dark-07b-recap-clock")
        popToRoot(app)

        openSettings(app)
        capture(app, wait: 3, name: "dark-10-settings")

        tapIfExists(app.cells["Your Year in Music"], in: app)
        capture(app, wait: 6, name: "dark-08-year-in-music")
        tapIfExists(app.buttons["Close"], in: app)
        sleep(1)

        scrollTo(app.cells["Listening Guide"], in: app)
        tapIfExists(app.cells["Listening Guide"], in: app)
        capture(app, wait: 4, name: "dark-09-listening-guide")
    }

    func testSongsListShot() throws {
        let app = launchApp()
        sleep(6)
        app.buttons["Songs"].firstMatch.tap()
        sleep(2)
        toggleLayoutToList(app)
        let prefix = ProcessInfo.processInfo.environment["SHOT_PREFIX"] ?? "dark"
        capture(app, wait: 6, name: "\(prefix)-02-library-songs")
        toggleLayoutToGrid(app)
    }

    func testPaywallShot() throws {
        let app = launchApp()
        sleep(6)
        openSettings(app)
        tapIfExists(app.cells["Unlock Lifetime"], in: app)
        capture(app, wait: 4, name: "dark-11-paywall")
    }

    func testSortSanity() throws {
        let app = launchApp()
        sleep(6)
        openSortMenuAndPick(app, option: "Artist")
        capture(app, wait: 2, name: "sort-albums-artist")
        openSortMenuAndPick(app, option: "Year")
        capture(app, wait: 2, name: "sort-albums-year")
        openSortMenuAndPick(app, option: "Title")
        capture(app, wait: 2, name: "sort-albums-title")

        app.buttons["Artists"].firstMatch.tap()
        sleep(2)
        openSortMenuAndPick(app, option: "Album Count")
        capture(app, wait: 2, name: "sort-artists-count")
        openSortMenuAndPick(app, option: "Name")
        capture(app, wait: 2, name: "sort-artists-name")
    }

    private func openSortMenuAndPick(_ app: XCUIApplication, option: String) {
        let nav = app.navigationBars.firstMatch
        let sortButton = nav.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'sort' OR identifier CONTAINS 'arrow'")
        ).firstMatch
        if sortButton.exists && sortButton.isHittable {
            sortButton.tap()
        } else {
            nav.buttons.element(boundBy: nav.buttons.count - 1).tap()
        }
        sleep(1)
        tapIfExists(app.buttons[option], in: app)
        sleep(1)
    }

    private func toggleLayoutToList(_ app: XCUIApplication) {
        tapIfExists(app.buttons["Layout: Grid. Double tap to change."], in: app)
    }

    private func toggleLayoutToGrid(_ app: XCUIApplication) {
        tapIfExists(app.buttons["Layout: List. Double tap to change."], in: app)
        tapIfExists(app.buttons["Layout: Compact. Double tap to change."], in: app)
    }

    func testLightTour() throws {
        let app = launchApp()
        capture(app, wait: 8, name: "light-01-library-grid")

        app.buttons["Songs"].firstMatch.tap()
        capture(app, wait: 6, name: "light-02-library-songs")

        app.buttons["Albums"].firstMatch.tap()
        sleep(1)
        openSettings(app)
        scrollTo(app.cells["Listening Guide"], in: app)
        tapIfExists(app.cells["Listening Guide"], in: app)
        capture(app, wait: 4, name: "light-09-listening-guide")
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, wait seconds: UInt32, name: String) {
        sleep(seconds)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: "\(outputDirectory)/\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }

    private func openAlbum(_ app: XCUIApplication, named title: String) {
        let cell = app.staticTexts[title].firstMatch
        if cell.waitForExistence(timeout: 10) {
            cell.tap()
        } else {
            app.cells.firstMatch.tap()
        }
    }

    private func startPlayback(_ app: XCUIApplication, trackNamed title: String) {
        let track = app.staticTexts[title].firstMatch
        if track.waitForExistence(timeout: 8) {
            track.tap()
        } else {
            app.cells.element(boundBy: 1).tap()
        }
        sleep(3)
    }

    private func expandNowPlaying(_ app: XCUIApplication) {
        let mini = app.otherElements["Schism, Tool"].firstMatch
        if mini.waitForExistence(timeout: 5) && mini.isHittable {
            mini.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.925)).tap()
        }
        sleep(3)
    }

    private func collapseNowPlaying(_ app: XCUIApplication) {
        tapIfExists(app.buttons["Collapse player"], in: app)
        sleep(2)
    }

    private func dismissSheet(_ app: XCUIApplication) {
        app.swipeDown(velocity: .fast)
        sleep(2)
    }

    private func popToRoot(_ app: XCUIApplication) {
        for _ in 0..<3 {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists, app.buttons["Albums"].firstMatch.isHittable == false else { break }
            back.tap()
            sleep(1)
        }
    }

    private func openSettings(_ app: XCUIApplication) {
        let bar = app.navigationBars.firstMatch
        bar.buttons.element(boundBy: 0).tap()
        _ = app.staticTexts["Settings"].waitForExistence(timeout: 5)
        sleep(1)
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.isHittable && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
    }

    private func tapIfExists(_ element: XCUIElement, in app: XCUIApplication) {
        if element.waitForExistence(timeout: 8) && element.isHittable {
            element.tap()
        }
    }
}
