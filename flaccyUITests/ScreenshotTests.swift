import XCTest

/// Drives the seeded demo library for App Store screenshots.
///
/// Every control is addressed by accessibility identifier, never by its label:
/// labels are localized into nine languages, so a label-driven tour silently
/// shoots the wrong screens in every locale but English. Seeded demo content
/// (album, track, and artist names) is not localized and is matched by name.
final class ScreenshotTests: XCTestCase {

    private enum ID {
        static let tabAlbums = "library.tab.albums"
        static let tabSongs = "library.tab.songs"
        static let tabArtists = "library.tab.artists"
        static let tabPlaylists = "library.tab.playlists"
        static let sort = "library.sort"
        static let settings = "library.settings"
        static let recap = "library.playlists.recap"
        static let settingsTable = "settings.table"
        static let listeningGuide = "settings.row.listeningGuide"
        static let yearInMusic = "settings.row.yearInMusic"
        static let yearInMusicClose = "yearInMusic.close"
        static let unlockLifetime = "unlockLifetime"
        static let playerExpand = "player.expand"
        static let playerCollapse = "player.collapse"
        static let playerLyrics = "player.lyrics"
        static let playerQueue = "player.queue"

        static func layoutToggle(showing mode: String) -> String { "library.layoutToggle.\(mode)" }
        static func sortOption(_ option: String) -> String { "sort.option.\(option)" }
        static func appearance(_ appearance: String) -> String { "settings.appearance.\(appearance)" }
    }

    private let outputDirectory = "/tmp/flaccy-shots/raw"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDarkTour() throws {
        let app = launchApp()
        capture(app, wait: 8, name: "dark-01-library-grid")

        tap(app.buttons[ID.tabSongs], "Songs tab")
        capture(app, wait: 6, name: "dark-02-library-songs")

        tap(app.buttons[ID.tabAlbums], "Albums tab")
        sleep(2)
        openAlbum(app, named: "Parallax Hours")
        capture(app, wait: 6, name: "dark-03-album-detail")

        startPlayback(app, trackNamed: "Slow Machine")
        expandNowPlaying(app)
        capture(app, wait: 6, name: "dark-04-now-playing")

        tap(app.buttons[ID.playerLyrics], "Lyrics toggle")
        capture(app, wait: 12, name: "dark-05-lyrics")
        tap(app.buttons[ID.playerLyrics], "Lyrics toggle")
        sleep(1)

        tap(app.buttons[ID.playerQueue], "Queue toggle")
        capture(app, wait: 3, name: "dark-06-queue")
        dismissSheet(app)

        collapseNowPlaying(app)
        popToRoot(app)

        tap(app.buttons[ID.tabPlaylists], "Playlists tab")
        sleep(2)
        tap(app.cells[ID.recap], "Recap row")
        capture(app, wait: 8, name: "dark-07-recap-charts")
        app.swipeUp(); app.swipeUp()
        capture(app, wait: 2, name: "dark-07b-recap-clock")
        popToRoot(app)

        openSettings(app)
        capture(app, wait: 3, name: "dark-10-settings")

        tap(app.cells[ID.yearInMusic], "Your Year in Music row")
        capture(app, wait: 6, name: "dark-08-year-in-music")
        tap(app.buttons[ID.yearInMusicClose], "Year in Music close button")
        sleep(1)

        scrollTo(app.cells[ID.listeningGuide], "Listening Guide row", in: app)
        tap(app.cells[ID.listeningGuide], "Listening Guide row")
        capture(app, wait: 4, name: "dark-09-listening-guide")
    }

    func testSongsListShot() throws {
        let app = launchApp()
        sleep(6)
        tap(app.buttons[ID.tabSongs], "Songs tab")
        sleep(2)
        cycleLayout(app, showing: "grid")
        let prefix = ProcessInfo.processInfo.environment["SHOT_PREFIX"] ?? "dark"
        capture(app, wait: 6, name: "\(prefix)-02-library-songs")
        cycleLayout(app, showing: "list")
        cycleLayout(app, showing: "compact")
    }

    func testPaywallShot() throws {
        let app = launchApp()
        sleep(6)
        openSettings(app)
        tap(app.buttons[ID.unlockLifetime], "Unlock Lifetime header button")
        capture(app, wait: 4, name: "dark-11-paywall")
    }

    func testSettingsShot() throws {
        let app = launchApp()
        sleep(6)
        openSettings(app)
        capture(app, wait: 2, name: "settings-01-hero")

        tap(app.buttons[ID.appearance("light")], "Light appearance segment")
        capture(app, wait: 2, name: "settings-02-light")

        tap(app.buttons[ID.appearance("dark")], "Dark appearance segment")
        capture(app, wait: 2, name: "settings-03-dark")

        app.swipeUp()
        capture(app, wait: 2, name: "settings-04-scrolled")
    }

    func testSortSanity() throws {
        let app = launchApp()
        sleep(6)
        openSortMenuAndPick(app, option: "artist")
        capture(app, wait: 2, name: "sort-albums-artist")
        openSortMenuAndPick(app, option: "year")
        capture(app, wait: 2, name: "sort-albums-year")
        openSortMenuAndPick(app, option: "title")
        capture(app, wait: 2, name: "sort-albums-title")

        tap(app.buttons[ID.tabArtists], "Artists tab")
        sleep(2)
        openSortMenuAndPick(app, option: "albumCount")
        capture(app, wait: 2, name: "sort-artists-count")
        openSortMenuAndPick(app, option: "name")
        capture(app, wait: 2, name: "sort-artists-name")
    }

    func testLightTour() throws {
        let app = launchApp()
        capture(app, wait: 8, name: "light-01-library-grid")

        tap(app.buttons[ID.tabSongs], "Songs tab")
        capture(app, wait: 6, name: "light-02-library-songs")

        tap(app.buttons[ID.tabAlbums], "Albums tab")
        sleep(1)
        openSettings(app)
        scrollTo(app.cells[ID.listeningGuide], "Listening Guide row", in: app)
        tap(app.cells[ID.listeningGuide], "Listening Guide row")
        capture(app, wait: 4, name: "light-09-listening-guide")
    }

    private func openSortMenuAndPick(
        _ app: XCUIApplication, option: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        tap(app.buttons[ID.sort], "sort menu button", file: file, line: line)
        sleep(1)
        tap(app.buttons[ID.sortOption(option)], "sort option \(option)", file: file, line: line)
        sleep(1)
    }

    /// Advances the layout toggle one step, asserting it is showing the mode the
    /// tour expects so a drifted starting layout fails instead of shooting the
    /// wrong density.
    private func cycleLayout(
        _ app: XCUIApplication, showing mode: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        tap(app.buttons[ID.layoutToggle(showing: mode)], "layout toggle showing \(mode)", file: file, line: line)
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--seed-screenshots")
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

    private func openAlbum(
        _ app: XCUIApplication, named title: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        tap(app.staticTexts[title].firstMatch, "album \(title)", file: file, line: line)
    }

    private func startPlayback(
        _ app: XCUIApplication, trackNamed title: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        tap(app.staticTexts[title].firstMatch, "track \(title)", file: file, line: line)
        sleep(3)
    }

    private func expandNowPlaying(
        _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        tap(app.buttons[ID.playerExpand], "mini player", file: file, line: line)
        sleep(3)
    }

    private func collapseNowPlaying(
        _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        tap(app.buttons[ID.playerCollapse], "collapse player control", file: file, line: line)
        sleep(2)
    }

    private func dismissSheet(_ app: XCUIApplication) {
        app.swipeDown(velocity: .fast)
        sleep(2)
    }

    private func popToRoot(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<3 {
            if app.buttons[ID.tabAlbums].isHittable { break }
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists else { break }
            back.tap()
            sleep(1)
        }
        XCTAssertTrue(
            waitUntilHittable(app.buttons[ID.tabAlbums], timeout: 5),
            "Did not get back to the library root",
            file: file, line: line
        )
    }

    private func openSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        tap(app.buttons[ID.settings], "settings button", file: file, line: line)
        XCTAssertTrue(
            app.tables[ID.settingsTable].waitForExistence(timeout: 5),
            "Settings did not open",
            file: file, line: line
        )
        sleep(1)
    }

    private func scrollTo(
        _ element: XCUIElement, _ description: String, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        var attempts = 0
        while !element.isHittable && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(element.isHittable, "Could not scroll \(description) into view", file: file, line: line)
    }

    /// Every tap in the tour goes through here: a step that cannot reach its
    /// target fails the test rather than degrading into a screenshot of
    /// whatever screen happened to be showing.
    private func tap(
        _ element: XCUIElement, _ description: String, timeout: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(
            waitUntilHittable(element, timeout: timeout),
            "Could not tap \(description): no hittable match after \(Int(timeout))s",
            file: file, line: line
        )
        element.tap()
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists && element.isHittable { return true }
            usleep(200_000)
        } while Date() < deadline
        return false
    }
}
