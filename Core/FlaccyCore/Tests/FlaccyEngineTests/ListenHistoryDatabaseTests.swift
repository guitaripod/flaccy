import FlaccyCore
import GRDB
import XCTest
@testable import FlaccyEngine

/// The database half of the shared listening history: every scrobble row
/// carries the listen keys, and counts, charts, dedup input and album plays
/// are all computed on them. The fixtures mirror `linux/library/src/db/listens.rs`.
final class ListenHistoryDatabaseTests: XCTestCase {

    private var directory: URL!
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-listens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try DatabaseManager(path: databasePath)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private var databasePath: String {
        directory.appendingPathComponent("library.sqlite").path
    }

    private func pulled(_ timestamp: TimeInterval, _ title: String, _ artist: String, _ album: String) -> DatabaseManager.PulledListen {
        DatabaseManager.PulledListen(title: title, artist: artist, album: album, timestamp: Date(timeIntervalSince1970: timestamp))
    }

    private func scrobble(_ timestamp: TimeInterval, _ title: String, _ artist: String, _ album: String, duration: Int = 200) -> ScrobbleRecord {
        ScrobbleRecord(
            trackTitle: title, artist: artist, albumTitle: album,
            timestamp: Date(timeIntervalSince1970: timestamp), duration: duration, submitted: false
        )
    }

    private func track(_ path: String, _ title: String, _ artist: String, remoteServer: String? = nil) -> TrackRecord {
        TrackRecord(
            fileURL: path, title: title, artist: artist, albumTitle: "Record", trackNumber: 1, duration: 200,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000), playCount: 0, aiAnalyzed: false,
            remoteServer: remoteServer
        )
    }

    private func playCount(_ path: String) throws -> Int {
        try XCTUnwrap(try db.fetchAllTracks().first { $0.fileURL == path }).playCount
    }

    private func storedKeys() throws -> [[String]] {
        let queue = try DatabaseQueue(path: databasePath)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT titleKey, artistKey, albumKey FROM scrobbles ORDER BY id").map {
                [$0["titleKey"], $0["artistKey"], $0["albumKey"]]
            }
        }
    }

    func testMigrationFillsTheKeysOfRowsStoredBeforeTheColumnsExisted() throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: databasePath)
        try DatabaseManager.migrator().migrate(queue, upTo: "v9")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO scrobbles (trackTitle, artist, albumTitle, timestamp, duration, submitted)
                VALUES ('Song (Remastered)', 'Beyoncé', 'Lemonade', '2024-01-01 00:00:00.000', 0, 1),
                       ('Song - 2011 Remaster', 'BEYONCE', 'Lemonade (Deluxe Edition)', '2024-01-02 00:00:00.000', 0, 1)
                """)
        }
        try queue.close()

        db = try DatabaseManager(path: databasePath)

        XCTAssertEqual(try storedKeys(), [["song", "beyonce", "lemonade"], ["song", "beyonce", "lemonade"]])
    }

    func testEveryInsertPathStoresTheKeys() throws {
        try db.insertScrobble(scrobble(1, "Hoppípolla (feat. Guest)", "Sigur Rós", "Takk..."))
        try db.insertScrobbles([scrobble(2, "Glósóli - 2011 Remaster", "Sigur Ros", "Takk... (Remastered)")])
        try db.insertPulledListens([pulled(3, "SÆGLÓPUR", "sigur rós", "")])

        let keys = try storedKeys()
        XCTAssertEqual(keys[0], [ListenHistory.titleKey("Hoppípolla"), ListenHistory.artistKey("Sigur Ros"), ListenHistory.albumKey("Takk...")])
        XCTAssertEqual(keys[1][0], ListenHistory.titleKey("Glósóli"))
        XCTAssertEqual(keys[1][1], keys[0][1])
        XCTAssertEqual(keys[1][2], keys[0][2])
        XCTAssertEqual(keys[2], [ListenHistory.titleKey("Sæglópur"), keys[0][1], ""])
    }

    func testPlaysCountUnderOneSongWhateverTheSpelling() throws {
        try db.insertPulledListens([
            pulled(1_700_000_000, "Hoppípolla", "Sigur Rós", "Takk..."),
            pulled(1_700_000_100, "Hoppipolla - 2011 Remaster", "Sigur Ros", "Takk... (Remastered)"),
            pulled(1_700_000_200, "HOPPIPOLLA", "sigur rós", "Takk..."),
            pulled(1_700_000_250, "Hoppípolla", "Sigur Rós", "Takk..."),
        ])
        try db.insertScrobble(scrobble(1_700_000_300, "Glósóli", "Sigur Rós", "Takk...", duration: 370))

        let key = ListenHistory.trackKey(title: "Hoppípolla", artist: "Sigur Rós")
        let counts = try db.scrobbleTrackCounts(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(counts.first { $0.key == key }?.count, 4)
        XCTAssertEqual(try db.playCountByTrack().first?.key, key)

        let artists = try db.scrobbleArtistCounts(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(artists.count, 1)
        XCTAssertEqual(artists[0].artist, "Sigur Rós")
        XCTAssertEqual(artists[0].count, 5)
        XCTAssertEqual(artists[0].seconds, 370 + 4 * DatabaseManager.unknownPlaySeconds)

        let tracks = try db.scrobbleTopTracks(from: .distantPast, to: .distantFuture, limit: 10)
        XCTAssertEqual(tracks[0].title, "Hoppípolla")
        XCTAssertEqual(tracks[0].artist, "Sigur Rós")
        XCTAssertEqual(tracks[0].count, 4)

        let albums = try db.scrobbleTopAlbums(from: Date(timeIntervalSince1970: 1_700_000_050), to: .distantFuture, limit: 10)
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].album, "Takk...")
        XCTAssertEqual(albums[0].artist, "Sigur Rós")
        XCTAssertEqual(albums[0].count, 4)
    }

    func testAPageStoredTwiceByOverlappingSyncsLandsOnce() throws {
        let page = [pulled(1_700_000_000, "Song", "A", ""), pulled(1_700_000_000, "Other", "A", "")]
        XCTAssertEqual(try db.insertPulledListens(page), 2)
        XCTAssertEqual(try db.insertPulledListens(page), 0)
        XCTAssertEqual(try db.scrobbleCountInRange(from: .distantPast, to: .distantFuture), 2)
    }

    func testTopListsApplyTheLimitAfterFolding() throws {
        try db.insertPulledListens([
            pulled(1, "One", "A", "X"), pulled(2, "ONE", "A", "X"),
            pulled(3, "Two", "B", "Y"), pulled(4, "Three", "C", "Z"),
        ])

        let tracks = try db.scrobbleTopTracks(from: .distantPast, to: .distantFuture, limit: 1)

        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].count, 2)
    }

    func testReconcileMatchesLibrarySongsByKeyAndTouchesOnlyChanges() throws {
        try db.insertTracks([
            track("a.flac", "Song (feat. Guest)", "Lead feat. Guest"),
            track("b.flac", "Other", "Lead"),
            track("remote.flac", "Song", "Lead", remoteServer: "server-1"),
        ])
        try db.insertPulledListens([
            pulled(1_700_000_000, "Song", "Lead", "Record"),
            pulled(1_700_000_500, "song - remastered", "LEAD", "Record"),
        ])

        XCTAssertEqual(try db.reconcilePlayCountsFromScrobbles(), 1)
        XCTAssertEqual(try playCount("a.flac"), 2)
        XCTAssertEqual(try playCount("b.flac"), 0)
        XCTAssertEqual(try playCount("remote.flac"), 0)
        XCTAssertEqual(try db.reconcilePlayCountsFromScrobbles(), 0)
    }

    func testAnAlbumCountsPlaysOfItsSongsFromThatReleaseOrNone() throws {
        try db.insertPulledListens([
            pulled(1, "Song", "Band", "Record (Deluxe Edition)"),
            pulled(2, "Song", "Band", ""),
            pulled(3, "Song", "Band", "Greatest Hits"),
            pulled(4, "Other", "Band", "Record"),
            pulled(5, "Unrelated", "Band", "Record"),
        ])
        let songs = [(title: "Song", artist: "Band"), (title: "Other", artist: "Band"), (title: "Song", artist: "Band")]

        XCTAssertEqual(try db.albumListenCount(albumTitle: "Record", songs: songs), 3)
    }

    func testStoredListensMarkThePlaysFlaccyRecordedAndNewestPulledIgnoresThem() throws {
        try db.insertScrobble(scrobble(1_700_000_000, "Here", "A", "", duration: 200))
        try db.insertPulledListens([pulled(1_700_000_100, "There", "A", "")])

        let stored = try db.storedListens(since: Date(timeIntervalSince1970: 1_699_999_999))

        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.contains { $0.playedHere && $0.titleKey == "here" && $0.timestamp == 1_700_000_000 })
        XCTAssertTrue(stored.contains { !$0.playedHere && $0.titleKey == "there" && $0.timestamp == 1_700_000_100 })
        XCTAssertEqual(try db.newestPulledListen(), Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(try db.storedListens(since: Date(timeIntervalSince1970: 1_700_000_050)).count, 1)
    }

    func testPulledListensBumpTheScrobbleRevision() throws {
        let before = db.scrobbleRevision
        try db.insertPulledListens([])
        XCTAssertEqual(db.scrobbleRevision, before)
        try db.insertPulledListens([pulled(1, "A", "B", "C")])
        XCTAssertEqual(db.scrobbleRevision, before + 1)
    }

    func testSyncStateRoundTripsPerAccount() throws {
        XCTAssertNil(try db.listenSyncState(account: "marcus"))
        var state = ListenHistory.SyncState().forAccount("marcus")
        state.backfillComplete = true
        state.newestRemote = 1_700_000_000
        state.lastSyncAt = 1_700_000_100

        try db.saveListenSyncState(state)
        state.lastSettleAt = 1_700_000_200
        try db.saveListenSyncState(state)

        XCTAssertEqual(try db.listenSyncState(account: "marcus"), state)
        XCTAssertNil(try db.listenSyncState(account: "someone"))
    }

    func testLibraryPlayLengthsAreRoundedKeyedByListenKeyAndLeaveRemoteSongsOut() throws {
        var long = track("a.flac", "Song (feat. Guest)", "Lead feat. Guest")
        long.duration = 200.6
        var remote = track("remote.flac", "Elsewhere", "Lead", remoteServer: "server-1")
        remote.duration = 300
        try db.insertTracks([long, remote])

        let lengths = try db.libraryPlayLengths()

        XCTAssertEqual(lengths, [ListenHistory.trackKey(title: "Song", artist: "Lead"): 201])
    }

    func testPlaysWithoutARecordedLengthAreWorthTheLibrarySongOrATypicalOne() throws {
        try db.insertPulledListens([
            pulled(1_700_000_000, "Song", "Lead", "Record"),
            pulled(1_700_000_100, "song - remastered", "LEAD", "Record"),
            pulled(1_700_000_200, "Unknown", "Other", ""),
        ])
        try db.insertScrobble(scrobble(1_700_000_300, "Recorded", "Lead", "Record", duration: 100))
        let lengths = [ListenHistory.trackKey(title: "Song", artist: "Lead"): 180]

        let totals = try db.scrobbleTotals(from: .distantPast, to: .distantFuture, libraryLengths: lengths)
        XCTAssertEqual(totals.plays, 4)
        XCTAssertEqual(totals.seconds, 2 * 180 + DatabaseManager.unknownPlaySeconds + 100)

        let artists = try db.scrobbleArtistCounts(from: .distantPast, to: .distantFuture, libraryLengths: lengths)
        XCTAssertEqual(artists.first { $0.artist == "Lead" }?.seconds, 2 * 180 + 100)
        XCTAssertEqual(artists.first { $0.artist == "Other" }?.seconds, DatabaseManager.unknownPlaySeconds)
        XCTAssertEqual(artists.reduce(0) { $0 + $1.seconds }, totals.seconds)

        let window = try db.scrobbleTotals(
            from: Date(timeIntervalSince1970: 1_700_000_050), to: Date(timeIntervalSince1970: 1_700_000_250),
            libraryLengths: lengths
        )
        XCTAssertEqual(window.seconds, 180 + DatabaseManager.unknownPlaySeconds)
    }
}
