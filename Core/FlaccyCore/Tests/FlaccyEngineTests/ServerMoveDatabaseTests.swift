import FlaccyCore
import GRDB
import XCTest
@testable import FlaccyEngine

/// Songs on this device becoming the server's songs: what the row keeps, what folds into it, what the journal holds.
final class ServerMoveDatabaseTests: XCTestCase {

    private var directory: URL!
    private var db: DatabaseManager!
    private let server = "srv"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flaccy-server-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try DatabaseManager(path: directory.appendingPathComponent("library.sqlite").path)
        try db.saveRemoteServer(RemoteServerRecord(
            id: server, name: "arch", baseURL: "http://arch:4545", username: "", authKind: .apiKey, addedAt: now
        ))
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func remotePath(_ song: String) -> String {
        RemoteTrackPath(serverID: server, songID: song).path
    }

    @discardableResult
    private func insertLocal(
        _ path: String, title: String = "Song", artist: String = "Artist", album: String = "Album", track: Int = 1,
        duration: Double = 200, loved: Bool = false, plays: Int = 0, lastPlayed: Date? = nil,
        added: Date = Date(timeIntervalSince1970: 1_700_000_000), size: Int64? = 5_000_000
    ) throws -> TrackRecord {
        var record = TrackRecord(
            fileURL: path, title: title, artist: artist, albumTitle: album, trackNumber: track, duration: duration,
            dateAdded: added, lastPlayed: lastPlayed, playCount: plays, aiAnalyzed: false, codec: "AAC"
        )
        record.loved = loved
        record.fileSize = size
        record.audioFingerprint = "sha256:\(path)"
        return try db.insertTrack(record)
    }

    @discardableResult
    private func insertRemote(
        _ song: String, title: String = "Song", artist: String = "Artist", album: String = "Album", track: Int = 1,
        duration: Double = 200, loved: Bool = false, plays: Int = 0, pinned: Bool = false
    ) throws -> TrackRecord {
        var record = TrackRecord(
            fileURL: remotePath(song), title: title, artist: artist, albumTitle: album, trackNumber: track,
            duration: duration, dateAdded: now, playCount: plays, aiAnalyzed: true, codec: "FLAC", bitDepth: 16,
            sampleRate: 44_100, channels: 2, fileSize: 30_000_000, audioFingerprint: "flac:\(song)",
            remoteServer: server, remoteSuffix: "flac", remoteSize: 30_000_000, remoteCoverArt: "al-1",
            remoteAlbumId: "al-1", pinned: pinned
        )
        record.loved = loved
        return try db.insertTrack(record)
    }

    private func row(_ path: String) throws -> TrackRecord? {
        try db.dbQueue.read { try TrackRecord.filter(Column("fileURL") == path).fetchOne($0) }
    }

    private func playlistPaths(_ id: Int64) throws -> [String] {
        try db.fetchPlaylistTracks(playlistId: id).map(\.trackFileURL)
    }

    func testInventoryKeysBothSidesAlikeAndHoldsBackEarlierMixes() throws {
        try insertLocal("A/one.m4a", title: "one", artist: "the artist")
        try insertLocal("A/two.m4a", title: "Two")
        try insertLocal("Samples/sample.m4a", title: "Sample")
        try insertLocal("A/mixed.m4a", title: "Mixed")
        try db.upsertPreviousVersion(PreviousVersionRecord(trackFileURL: "A/mixed.m4a", storedPath: "x", movedAt: now))
        try insertRemote("s1", title: "One", artist: "The Artist")
        try db.saveRemoteServer(RemoteServerRecord(
            id: "other", name: "nas", baseURL: "http://nas", username: "", authKind: .apiKey, addedAt: now
        ))
        var elsewhere = TrackRecord(
            fileURL: RemoteTrackPath(serverID: "other", songID: "x").path, title: "Two", artist: "Artist",
            albumTitle: "Album", trackNumber: 1, duration: 200, dateAdded: now, playCount: 0, aiAnalyzed: true
        )
        elsewhere.remoteServer = "other"
        try db.insertTrack(elsewhere)

        let inventory = try db.serverMoveInventory(serverID: server, excluded: { $0.hasPrefix("Samples/") }) { $0.loved ? 2 : 0 }

        XCTAssertEqual(Set(inventory.local.map(\.path)), ["A/one.m4a", "A/two.m4a"])
        XCTAssertEqual(inventory.server.map(\.path), [remotePath("s1")])
        XCTAssertEqual(inventory.heldBack, 1)
        XCTAssertEqual(inventory.localSongs["A/one.m4a"]?.bytes, 5_000_000)
        let one = try XCTUnwrap(inventory.local.first { $0.path == "A/one.m4a" })
        XCTAssertEqual(one.songKey, inventory.server[0].songKey)
        XCTAssertEqual(one.albumKey, inventory.server[0].albumKey)
        XCTAssertEqual(one.durationMs, 200_000)
        let plan = ServerMovePlan.plan(local: inventory.local, server: inventory.server)
        XCTAssertEqual(plan.pairs, [ServerMovePlan.Pair(local: "A/one.m4a", server: remotePath("s1"))])
    }

    func testAPairKeepsItsRowAndTakesTheServerSong() throws {
        let local = try insertLocal(
            "A/song.m4a", title: "song", loved: true, plays: 7, lastPlayed: Date(timeIntervalSince1970: 1_750_000_000)
        )
        try insertRemote("s1", title: "Song", plays: 3)
        let playlist = try db.createPlaylist(name: "Mix")
        try db.addTracksToPlaylist(playlistId: playlist.id!, trackFileURLs: ["A/song.m4a"])

        let records = try db.applyServerMove([.pair(local: "A/song.m4a", server: remotePath("s1"), keepOnDevice: false)], now: now)

        XCTAssertEqual(records, [ServerMoveRecord(
            localPath: "A/song.m4a", remotePath: remotePath("s1"), keepOnDevice: false, fileSize: 5_000_000, starOnServer: true
        )])
        XCTAssertNil(try row("A/song.m4a"))
        let moved = try XCTUnwrap(try row(remotePath("s1")))
        XCTAssertEqual(moved.id, local.id)
        XCTAssertEqual(moved.title, "Song")
        XCTAssertEqual(moved.remoteServer, server)
        XCTAssertEqual(moved.remoteSuffix, "flac")
        XCTAssertEqual(moved.codec, "FLAC")
        XCTAssertEqual(moved.audioFingerprint, "flac:s1")
        XCTAssertEqual(moved.fileSize, 30_000_000)
        XCTAssertTrue(moved.loved)
        XCTAssertEqual(moved.playCount, 7)
        XCTAssertEqual(moved.lastPlayed, Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(moved.dateAdded, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertFalse(moved.pinned)
        XCTAssertEqual(try playlistPaths(playlist.id!), [remotePath("s1")])
        let count = try db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tracks") }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(
            try db.pendingServerMoves(),
            [ServerMoveRecord(localPath: "A/song.m4a", remotePath: remotePath("s1"), keepOnDevice: false, fileSize: 5_000_000)]
        )
        XCTAssertEqual(try db.pendingServerMoveLocalPaths(), ["A/song.m4a"])
    }

    func testKeepingOnTheDevicePinsTheSong() throws {
        try insertLocal("A/song.m4a")
        try insertRemote("s1", loved: true)

        let records = try db.applyServerMove([.pair(local: "A/song.m4a", server: remotePath("s1"), keepOnDevice: true)], now: now)

        XCTAssertEqual(records.first?.starOnServer, false)
        XCTAssertTrue(try XCTUnwrap(try row(remotePath("s1"))).pinned)
        XCTAssertTrue(try XCTUnwrap(try row(remotePath("s1"))).loved)
    }

    func testTheServersOwnPlaylistPlacesStay() throws {
        try insertLocal("A/song.m4a")
        try insertRemote("s1")
        let playlist = try db.createPlaylist(name: "Both")
        try db.addTracksToPlaylist(playlistId: playlist.id!, trackFileURLs: [remotePath("s1"), "A/song.m4a"])

        _ = try db.applyServerMove([.pair(local: "A/song.m4a", server: remotePath("s1"), keepOnDevice: false)], now: now)

        XCTAssertEqual(try playlistPaths(playlist.id!), [remotePath("s1"), remotePath("s1")])
    }

    func testADuplicateFoldsIntoThePair() throws {
        try insertLocal("A/song.m4a", plays: 2)
        try insertLocal("B/song.m4a", loved: true, plays: 5, added: Date(timeIntervalSince1970: 1_600_000_000))
        try insertRemote("s1")
        let playlist = try db.createPlaylist(name: "Copy")
        try db.addTracksToPlaylist(playlistId: playlist.id!, trackFileURLs: ["B/song.m4a"])

        let records = try db.applyServerMove([
            .pair(local: "A/song.m4a", server: remotePath("s1"), keepOnDevice: true),
            .duplicate(local: "B/song.m4a", server: remotePath("s1")),
        ], now: now)

        XCTAssertEqual(records.map(\.localPath), ["A/song.m4a", "B/song.m4a"])
        XCTAssertEqual(records.map(\.keepOnDevice), [true, false])
        XCTAssertEqual(records.map(\.starOnServer), [false, true])
        XCTAssertNil(try row("B/song.m4a"))
        let moved = try XCTUnwrap(try row(remotePath("s1")))
        XCTAssertEqual(moved.playCount, 7)
        XCTAssertTrue(moved.loved)
        XCTAssertEqual(moved.dateAdded, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertEqual(try playlistPaths(playlist.id!), [remotePath("s1")])
        XCTAssertEqual(try db.serverMoveFormerPaths(), [remotePath("s1"): "A/song.m4a"])
    }

    func testStepsWhoseRowsChangedAreSkipped() throws {
        try insertLocal("A/versioned.m4a")
        try db.upsertPreviousVersion(PreviousVersionRecord(trackFileURL: "A/versioned.m4a", storedPath: "x", movedAt: now))
        try insertRemote("s1")
        try insertLocal("A/song.m4a")

        let records = try db.applyServerMove([
            .pair(local: "A/gone.m4a", server: remotePath("s1"), keepOnDevice: false),
            .pair(local: "A/song.m4a", server: remotePath("missing"), keepOnDevice: false),
            .pair(local: "A/versioned.m4a", server: remotePath("s1"), keepOnDevice: false),
            .duplicate(local: "A/song.m4a", server: remotePath("missing")),
        ], now: now)

        XCTAssertEqual(records, [])
        XCTAssertNotNil(try row("A/song.m4a"))
        XCTAssertNotNil(try row("A/versioned.m4a"))
        XCTAssertNotNil(try row(remotePath("s1")))
        XCTAssertEqual(try db.pendingServerMoves(), [])
    }

    func testFinishingAndAbandoningEmptyThePendingList() throws {
        try insertLocal("A/one.m4a", title: "One")
        try insertLocal("A/two.m4a", title: "Two")
        try insertRemote("s1", title: "One")
        try insertRemote("s2", title: "Two")
        _ = try db.applyServerMove([
            .pair(local: "A/one.m4a", server: remotePath("s1"), keepOnDevice: false),
            .pair(local: "A/two.m4a", server: remotePath("s2"), keepOnDevice: false),
        ], now: now)

        try db.finishServerMoves(localPaths: ["A/one.m4a"])
        try db.abandonServerMove(localPath: "A/two.m4a")

        XCTAssertEqual(try db.pendingServerMoves(), [])
        XCTAssertEqual(try db.serverMoveFormerPaths(), [remotePath("s1"): "A/one.m4a"])
        XCTAssertTrue(try db.hasRemoteRow(path: remotePath("s1")))
        XCTAssertFalse(try db.hasRemoteRow(path: "A/one.m4a"))
    }

    func testRemovingTheServerForgetsFinishedMovesButKeepsPendingOnes() throws {
        try insertLocal("A/one.m4a", title: "One")
        try insertLocal("A/two.m4a", title: "Two")
        try insertRemote("s1", title: "One")
        try insertRemote("s2", title: "Two")
        _ = try db.applyServerMove([
            .pair(local: "A/one.m4a", server: remotePath("s1"), keepOnDevice: false),
            .pair(local: "A/two.m4a", server: remotePath("s2"), keepOnDevice: false),
        ], now: now)
        try db.finishServerMoves(localPaths: ["A/one.m4a"])

        try db.deleteRemoteServer(id: server)

        XCTAssertEqual(try db.pendingServerMoves().map(\.localPath), ["A/two.m4a"])
        XCTAssertFalse(try db.hasRemoteRow(path: remotePath("s2")))
        XCTAssertEqual(try db.serverMoveFormerPaths(), [:])
    }

    func testLyricsAndTheirOffsetFollowANewSpelling() throws {
        try insertLocal("A/song.m4a", title: "song", artist: "artist")
        try insertRemote("s1", title: "Song", artist: "Artist")
        try db.saveLyrics(LyricsRecord(trackTitle: "song", artist: "artist", plainLyrics: "la la", instrumental: false, offsetMs: 350))

        _ = try db.applyServerMove([.pair(local: "A/song.m4a", server: remotePath("s1"), keepOnDevice: false)], now: now)

        let carried = try XCTUnwrap(try db.fetchLyrics(trackTitle: "Song", artist: "Artist"))
        XCTAssertEqual(carried.plainLyrics, "la la")
        XCTAssertEqual(carried.offsetMs, 350)
    }

    func testAnOffsetThePersonSetWinsOverLyricsTheServerSpellingAlreadyHas() throws {
        try insertLocal("A/song.m4a", title: "song", artist: "artist")
        try insertRemote("s1", title: "Song", artist: "Artist")
        try db.saveLyrics(LyricsRecord(trackTitle: "song", artist: "artist", plainLyrics: "mine", instrumental: false, offsetMs: -420))
        try db.saveLyrics(LyricsRecord(trackTitle: "Song", artist: "Artist", plainLyrics: "fetched", instrumental: false))

        _ = try db.applyServerMove([.pair(local: "A/song.m4a", server: remotePath("s1"), keepOnDevice: false)], now: now)

        let lyrics = try XCTUnwrap(try db.fetchLyrics(trackTitle: "Song", artist: "Artist"))
        XCTAssertEqual(lyrics.plainLyrics, "fetched")
        XCTAssertEqual(lyrics.offsetMs, -420)
    }

    func testAFurtherCopyBringsItsLyricsOffset() throws {
        try insertLocal("A/song.m4a", title: "Song")
        try insertLocal("B/song.m4a", title: "song (remastered)")
        try insertRemote("s1", title: "Song")
        try db.saveLyrics(LyricsRecord(trackTitle: "song (remastered)", artist: "Artist", plainLyrics: "la", instrumental: false, offsetMs: 200))

        _ = try db.applyServerMove([
            .pair(local: "A/song.m4a", server: remotePath("s1"), keepOnDevice: false),
            .duplicate(local: "B/song.m4a", server: remotePath("s1")),
        ], now: now)

        XCTAssertEqual(try db.fetchLyrics(trackTitle: "Song", artist: "Artist")?.offsetMs, 200)
    }

    func testHidingAndShowingTheServerKeepsAMovedSongsPlays() throws {
        let local = try insertLocal(
            "A/song.m4a", loved: true, plays: 40, lastPlayed: Date(timeIntervalSince1970: 1_750_000_000)
        )
        try insertRemote("s1")
        _ = try db.applyServerMove([.pair(local: "A/song.m4a", server: remotePath("s1"), keepOnDevice: false)], now: now)

        try db.deleteRemoteTracks(serverID: server)
        XCTAssertNil(try row(remotePath("s1")))
        let facts = RemoteSongFacts(
            title: "Song", artist: "Artist", albumTitle: "Album", albumArtist: nil, trackNumber: 1, duration: 200,
            suffix: "flac", size: 30_000_000, coverArt: nil, albumId: nil, codec: "FLAC", bitDepth: 16, sampleRate: 44_100,
            channels: 2, fingerprint: "flac:s1"
        )
        try db.applyRemoteCatalog(RemoteCatalogChange(
            serverID: server, inserts: [(songID: "s1", facts: facts)], updates: [], newVersions: [], removedSongIDs: [],
            playStates: [], now: now.addingTimeInterval(3_600)
        ))

        let back = try XCTUnwrap(try row(remotePath("s1")))
        XCTAssertEqual(back.playCount, 40)
        XCTAssertTrue(back.loved)
        XCTAssertEqual(back.lastPlayed, Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(back.dateAdded, local.dateAdded)
        let left = try db.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM hiddenRemoteState") }
        XCTAssertEqual(left, 0)
    }

    func testACustomCoverFollowsANewAlbumSpelling() throws {
        try insertLocal("A/song.m4a", album: "Album - Disc 2")
        try insertRemote("s1", album: "Album")
        try db.saveCustomCover(Data([1, 2, 3]), forKeys: [(title: "Album - Disc 2", artist: "Artist")])

        _ = try db.applyServerMove([.pair(local: "A/song.m4a", server: remotePath("s1"), keepOnDevice: false)], now: now)

        XCTAssertTrue(db.hasCustomCover(forKeys: [(title: "Album", artist: "Artist")]))
    }
}
