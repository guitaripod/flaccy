import FlaccyCore
import GRDB
import XCTest
@testable import FlaccyEngine

/// The database-folded counts Home's mixes, the lyrics lane and Home's history read agree with
/// counting every play row by row, the way they were read before.
final class ListeningAggregateTests: XCTestCase {

    private var directory: URL!
    private var db: DatabaseManager!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-aggregates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func play(daysAgo: Double, _ title: String, _ artist: String, _ album: String) -> ScrobbleRecord {
        ScrobbleRecord(
            trackTitle: title, artist: artist, albumTitle: album,
            timestamp: now.addingTimeInterval(-daysAgo * 86_400), duration: 200, submitted: true
        )
    }

    private func seed() throws {
        try db.insertScrobbles([
            play(daysAgo: 1, "Hoppípolla", "Sigur Rós", "Takk..."),
            play(daysAgo: 2, "Hoppípolla", "Sigur Rós", "Takk..."),
            play(daysAgo: 40, "Hoppipolla (Remastered)", "SIGUR ROS", "Takk... (Deluxe)"),
            play(daysAgo: 200, "Glósóli", "Sigur Rós", "Takk..."),
            play(daysAgo: 3, "Teardrop", "Massive Attack", "Mezzanine"),
            play(daysAgo: 95, "Teardrop", "massive attack", "Mezzanine"),
            play(daysAgo: 400, "Angel", "Massive Attack", "Mezzanine"),
            play(daysAgo: 10, "Svefn-g-englar", "Sigur Rós", "Ágætis byrjun"),
        ])
    }

    private func countedByRow(since windows: [Date]) throws -> (total: [String: Int], since: [[String: Int]], artists: [String: Int]) {
        var total: [String: Int] = [:]
        var since = Array(repeating: [String: Int](), count: windows.count)
        var artists: [String: Int] = [:]
        for listen in try db.fetchListens() {
            total[listen.key, default: 0] += 1
            artists[listen.artist.lowercased(), default: 0] += 1
            for (index, start) in windows.enumerated() where listen.timestamp >= start {
                since[index][listen.key, default: 0] += 1
            }
        }
        return (total, since, artists)
    }

    func testFoldedTalliesMatchCountingEveryPlay() throws {
        try seed()
        let windows = [now.addingTimeInterval(-90 * 86_400), now.addingTimeInterval(-30 * 86_400)]
        let folded = try db.playTallies(since: windows)
        let counted = try countedByRow(since: windows)
        XCTAssertEqual(folded.total, counted.total)
        XCTAssertEqual(folded.since, counted.since)
        XCTAssertEqual(folded.artists, counted.artists)
        XCTAssertEqual(folded.total.values.reduce(0, +), 8)
    }

    func testRowsStoredWithoutKeysFoldToTheKeysAPlayWouldHave() throws {
        try seed()
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("library.sqlite").path)
        try queue.write { db in
            try db.execute(sql: "UPDATE scrobbles SET titleKey = '', artistKey = '' WHERE trackTitle = 'Angel'")
        }
        try queue.close()
        let windows = [now.addingTimeInterval(-500 * 86_400)]
        let folded = try db.playTallies(since: windows)
        XCTAssertEqual(folded.total, try countedByRow(since: windows).total)
        XCTAssertEqual(folded.total[ListenHistory.trackKey(title: "Angel", artist: "Massive Attack")], 1)
    }

    func testArtistsAreLeftUncountedWhenNotAsked() throws {
        try seed()
        let folded = try db.playTallies(since: [], countingArtists: false)
        XCTAssertTrue(folded.artists.isEmpty)
        XCTAssertEqual(folded.total.values.reduce(0, +), 8)
    }

    func testRecentAlbumsAreTheNewestDistinctAlbumsAWholeGroupingWouldPick() throws {
        try seed()
        let earliest = now.addingTimeInterval(-300 * 86_400)
        let grouped = try db.lastPlayedByAlbum()
            .filter { $0.lastPlayed >= earliest }
            .sorted { $0.lastPlayed > $1.lastPlayed }
            .prefix(3)
            .map { [$0.albumTitle, $0.artist, "\($0.lastPlayed.timeIntervalSince1970)"] }
        let walked = try db.recentlyPlayedAlbums(limit: 3, since: earliest)
            .map { [$0.albumTitle, $0.artist, "\($0.lastPlayed.timeIntervalSince1970)"] }
        XCTAssertEqual(walked, Array(grouped))
        XCTAssertEqual(walked.first?.first, "Takk...")
    }

    func testLivePlaysAreFoundWithoutCounting() throws {
        XCTAssertFalse(try db.hasLivePlays())
        try seed()
        XCTAssertTrue(try db.hasLivePlays())
    }
}
