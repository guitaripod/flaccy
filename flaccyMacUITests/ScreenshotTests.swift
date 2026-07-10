import XCTest

final class ScreenshotTests: XCTestCase {

    private static let outputDirectory = URL(fileURLWithPath: "/tmp/flaccy-mac-shots/raw", isDirectory: true)

    override func setUpWithError() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
    }

    func testAlbumsGrid() throws {
        try captureFrame(name: "mac-1-albums", arguments: ["--shot-section", "albums"], settle: 14)
    }

    func testAlbumDetail() throws {
        try captureFrame(name: "mac-2-album-detail", arguments: ["--shot-album", "Parallax Hours"], settle: 16)
    }

    func testNowPlayingLyrics() throws {
        try captureFrame(name: "mac-3-nowplaying-lyrics", arguments: ["--shot-nowplaying-lyrics"], settle: 22)
    }

    func testSongsTable() throws {
        try captureFrame(name: "mac-4-songs", arguments: ["--shot-section", "songs"], settle: 14)
    }

    func testChartsDashboard() throws {
        try captureFrame(name: "mac-5-charts", arguments: ["--shot-section", "charts"], settle: 18)
    }

    func testYearInMusic() throws {
        try captureFrame(name: "mac-6-yearinmusic", arguments: ["--shot-section", "yearinmusic"], settle: 18)
    }

    func testQueuePanel() throws {
        try captureFrame(name: "mac-7-queue", arguments: ["--shot-queue"], settle: 20)
    }

    func testArtistDetail() throws {
        try captureFrame(name: "mac-8-artist", arguments: ["--shot-artist", "Meridian Wolde"], settle: 16)
    }

    private func captureFrame(name: String, arguments: [String], settle: TimeInterval) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-screenshots", "--window-size", "1440x900"] + arguments
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "main window never appeared for \(name)")
        Thread.sleep(forTimeInterval: settle)

        try write(window.screenshot(), suffix: "window", name: name)
        try write(XCUIScreen.main.screenshot(), suffix: "screen", name: name)
        app.terminate()
    }

    private func write(_ screenshot: XCUIScreenshot, suffix: String, name: String) throws {
        let url = Self.outputDirectory.appendingPathComponent("\(name)-\(suffix).png")
        try screenshot.pngRepresentation.write(to: url)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(name)-\(suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
