import FlaccyCore
import FlaccyServerCore
import Foundation
import GRDB
import XCTest

@testable import FlaccyEngine

final class ServerSyncMaterializeTests: XCTestCase {

    private func ref(_ title: String, artist: String = "Artist", album: String = "Album") throws -> ServerSongRef {
        try ServerSongIdentity.ref(title: title, artist: artist, album: album)
    }

    func testEntriesForSongsTheLibraryLacksWaitAsGhostsAndAppearWhenAScanFindsThem() async throws {
        let server = FakeFlaccyServer()
        let author = try makeDevice(server)
        let reader = try makeDevice(server)
        server.newCode("SECOND")
        let songs = try ["A", "B", "C"].map { try author.addTrack($0) }
        _ = try await author.connect()
        let playlist = try XCTUnwrap(author.database.createPlaylist(name: "Mix").id)
        try author.database.addTracksToPlaylist(playlistId: playlist, trackFileURLs: songs.map(\.fileURL))
        assertUpToDate(await author.settle())

        try reader.addTrack("B")
        _ = try await reader.connect(code: "SECOND")
        assertUpToDate(await reader.settle())
        XCTAssertEqual(try reader.playlistTitles("Mix"), ["B"])
        XCTAssertEqual(try reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_ghosts") }, 2)

        try reader.addTrack("A")
        try reader.addTrack("C")
        await reader.engine.resolveGhosts()
        XCTAssertEqual(try reader.playlistTitles("Mix"), ["A", "B", "C"])
        XCTAssertEqual(try reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_ghosts") }, 0)
    }

    func testEntriesResolveBySongKeyPreferringTheSameAlbumAndLosslessFiles() async throws {
        let server = FakeFlaccyServer()
        let author = try makeDevice(server)
        let reader = try makeDevice(server)
        server.newCode("SECOND")
        let studio = try author.addTrack("Song", album: "Studio", path: "a/studio.flac")
        _ = try await author.connect()
        let playlist = try XCTUnwrap(author.database.createPlaylist(name: "Mix").id)
        try author.database.addTrackToPlaylist(playlistId: playlist, trackFileURL: studio.fileURL)
        assertUpToDate(await author.settle())

        try reader.addTrack("Song", album: "Live", path: "z/live.flac")
        try reader.addTrack("Song", album: "Studio", path: "m/studio.mp3", codec: "MP3")
        try reader.addTrack("Song", album: "Studio", path: "b/studio.flac")
        _ = try await reader.connect(code: "SECOND")
        assertUpToDate(await reader.settle())
        let paths = try reader.read { try String.fetchAll($0, sql: "SELECT trackFileURL FROM playlistTracks") }
        XCTAssertEqual(paths, ["b/studio.flac"])
    }

    func testALoveFromTheServerLovesEveryMatchingLocalTrackAndAnUnloveClearsThem() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        let studio = try device.addTrack("Song", album: "Studio", path: "a/studio.flac")
        let live = try device.addTrack("Song", album: "Live", path: "b/live.flac")
        let other = try device.addTrack("Other")
        _ = try await device.connect()
        let song = try ref("Song")
        try server.plantLove(song, loved: true, stamp: Int64(Date().timeIntervalSince1970 * 1000) << 16)
        assertUpToDate(await device.settle())
        XCTAssertTrue(try device.isLoved(studio.fileURL))
        XCTAssertTrue(try device.isLoved(live.fileURL))
        XCTAssertFalse(try device.isLoved(other.fileURL))
        XCTAssertEqual(try device.pendingNames(), [], "a materialized love is not a local write")

        try server.plantLove(song, loved: false, stamp: (Int64(Date().timeIntervalSince1970 * 1000) + 1_000) << 16)
        assertUpToDate(await device.settle())
        XCTAssertFalse(try device.isLoved(studio.fileURL))
        XCTAssertFalse(try device.isLoved(live.fileURL))
    }

    func testAPendingLocalLoveShowsOverTheServersOlderState() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        let song = try device.addTrack("Song")
        _ = try await device.connect()
        try server.plantLove(try ref("Song"), loved: true, stamp: Int64(1_000) << 16)
        assertUpToDate(await device.settle())
        XCTAssertTrue(try device.isLoved(song.fileURL))
        server.online = false
        try device.database.setLoved(fileURL: song.fileURL, loved: false, pendingOp: nil)
        _ = await device.settle()
        XCTAssertFalse(try device.isLoved(song.fileURL))
        server.online = true
        assertUpToDate(await device.settle())
        XCTAssertFalse(try device.isLoved(song.fileURL))
        XCTAssertEqual(server.snapshot().loves.values.first?.loved, false)
    }

    func testSyncedLyricOffsetsReachLyricsRowsNowOrWhenTheLyricsAppear() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try device.addTrack("Song", album: "Album")
        try device.database.saveLyrics(LyricsRecord(trackTitle: "Song", artist: "Artist", instrumental: false))
        _ = try await device.connect()
        let key = try device.songKey("Song")
        try server.plantScalar("lyr/\(key)", .int(400), stamp: Int64(1_000) << 16)
        assertUpToDate(await device.settle())
        XCTAssertEqual(try device.database.fetchLyrics(trackTitle: "Song", artist: "Artist")?.offsetMs, 400)

        _ = try device.addTrack("Later")
        let laterKey = try device.songKey("Later")
        try server.plantScalar("lyr/\(laterKey)", .int(90), stamp: Int64(1_000) << 16)
        assertUpToDate(await device.settle())
        try device.database.saveLyrics(LyricsRecord(trackTitle: "Later", artist: "Artist", instrumental: false))
        await device.engine.resolveGhosts()
        XCTAssertEqual(try device.database.fetchLyrics(trackTitle: "Later", artist: "Artist")?.offsetMs, 90)
        XCTAssertEqual(device.sink.calls.count, 0, "lyric offsets never reach the scalar sink")
    }

    func testOtherScalarsGoToTheSinkAndClearingThemResetsTheSetting() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        try server.plantScalar("pref/theme", "dark", stamp: Int64(1_000) << 16)
        try server.plantScalar("eq/profile", ["gain": 3], stamp: Int64(1_000) << 16)
        assertUpToDate(await device.settle())
        let applied = Dictionary(uniqueKeysWithValues: device.sink.calls.map { ($0.key, $0.value) })
        XCTAssertEqual(applied["pref/theme"], .some("dark"))
        XCTAssertEqual(applied["eq/profile"], .some(["gain": 3]))

        try server.plantScalar("pref/theme", nil, stamp: Int64(2_000) << 16)
        assertUpToDate(await device.settle())
        XCTAssertEqual(device.sink.calls.last?.key, "pref/theme")
        XCTAssertNil(device.sink.calls.last?.value ?? nil)
    }

    func testLocalScalarWritesFoldOverTheBaseAndGoToTheServer() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        try device.write { db in
            let recorder = try XCTUnwrap(ServerSyncRecorder(db, gate: device.database.serverSyncGate))
            try recorder.scalar(key: "pref/theme", value: "light")
            try recorder.scalar(key: "bogus/key", value: 1)
            try recorder.scalarCleared(key: "eq/old")
        }
        XCTAssertEqual(try device.pendingNames(), ["scalar.set", "scalar.clear"])
        assertUpToDate(await device.settle())
        XCTAssertEqual(server.snapshot().scalars["pref/theme"]?.value, .string("light"))
        XCTAssertEqual(server.snapshot().scalars["eq/old"]?.deleted, true)
    }

    func testPlaysArePulledBackwardsThenForwardsAndAdoptTheLocalRowsTheyDuplicate() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        assertUpToDate(await device.settle())
        let base: Int64 = 1_700_000_000
        for index in 0..<7 {
            server.plantPlay(ServerListenItem(
                seq: 0, eventId: String(format: "%024x", index + 1), ts: base + Int64(index) * 100,
                ref: try ref("Song \(index)"), playedS: index == 3 ? 0 : 200, source: index == 3 ? .lastfm : .flaccy,
                recorded: index != 3
            ))
        }
        try device.database.insertPulledListens([
            DatabaseManager.PulledListen(
                title: "Song 3", artist: "Artist", album: "Album", timestamp: Date(timeIntervalSince1970: TimeInterval(base + 300))
            ),
        ])
        try device.write { db in
            try SyncMeta.remove(db, SyncMeta.listensPhase)
            try SyncMeta.remove(db, SyncMeta.listensBefore)
            try SyncMeta.remove(db, SyncMeta.listensTailFrom)
        }
        server.pageCap = 3
        assertUpToDate(await device.settle())
        XCTAssertEqual(try device.scrobbleCount(), 7, "the Last.fm row already here was adopted, not duplicated")
        let adopted = try device.read { try String.fetchOne($0, sql: "SELECT eventId FROM scrobbles WHERE trackTitle = 'Song 3'") }
        XCTAssertEqual(adopted, String(format: "%024x", 4))
        XCTAssertEqual(try device.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM scrobbles WHERE submitted = 0") }, 0)

        let before = server.callCount("listens")
        server.plantPlay(ServerListenItem(seq: 0, eventId: String(format: "%024x", 99), ts: base + 5_000, ref: try ref("Song 9"), playedS: 100))
        assertUpToDate(await device.settle())
        XCTAssertEqual(try device.scrobbleCount(), 8)
        XCTAssertEqual(server.callCount("listens") - before, 1, "the second round reads only the tail")
    }

    func testTheServersLedgerVerdictHidesAPlayFromEveryCount() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        let second: Int64 = 1_700_000_000
        server.plantPlay(ServerListenItem(seq: 0, eventId: String(format: "%024x", 1), ts: second, ref: try ref("Same"), playedS: 200))
        server.plantPlay(ServerListenItem(seq: 0, eventId: String(format: "%024x", 2), ts: second, ref: try ref("Same"), playedS: 0, source: .lastfm, recorded: false, suppressed: true))
        _ = try await device.connect()
        assertUpToDate(await device.settle())
        XCTAssertEqual(try device.scrobbleCount(), 2)
        XCTAssertEqual(try device.database.scrobbleCount(submittedOnly: false), 1)
        XCTAssertEqual(try device.database.playCountByTrack().map(\.count), [1])

        server.plantPlay(ServerListenItem(seq: 0, eventId: String(format: "%024x", 2), ts: second, ref: try ref("Same"), playedS: 0, source: .lastfm, recorded: false, suppressed: false))
        assertUpToDate(await device.settle())
        XCTAssertEqual(try device.database.scrobbleCount(submittedOnly: false), 2)
    }

    func testOwnPlaysEchoBackWithoutDuplicatingAndTheLedgerCanHideThem() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        let second = Date().timeIntervalSince1970 - 3_000
        try device.play("Same", at: second)
        assertUpToDate(await device.settle())
        XCTAssertEqual(try device.scrobbleCount(), 1)
        XCTAssertEqual(server.visiblePlays().count, 1)
        let stored = server.snapshot().plays.values.first
        XCTAssertEqual(stored?.item.device, try XCTUnwrap(ServerSyncStore(database: device.database).link()).device)
    }

    func testCoversTravelAsBlobsAndAreFetchedByTheDeviceThatLacksThem() async throws {
        let server = FakeFlaccyServer()
        let author = try makeDevice(server)
        let reader = try makeDevice(server)
        server.newCode("SECOND")
        _ = try await author.connect()
        _ = try await reader.connect(code: "SECOND")
        let playlist = try XCTUnwrap(author.database.createPlaylist(name: "Mix").id)
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 5, 6, 7, 8])
        try author.database.savePlaylistCover(image, id: playlist)
        assertUpToDate(await author.settle())
        XCTAssertEqual(server.snapshot().blobs[SyncMaterializer.hexDigest(image)], image)

        assertUpToDate(await reader.settle())
        let readerPlaylist = try reader.playlistID("Mix")
        XCTAssertEqual(try reader.database.playlistCover(id: readerPlaylist), image)

        try author.database.clearPlaylistCover(id: playlist)
        assertUpToDate(await author.settle())
        assertUpToDate(await reader.settle())
        XCTAssertNil(try reader.database.playlistCover(id: readerPlaylist))
    }

    func testAPlaylistDeletedOnAnotherDeviceDisappearsHereWithItsRows() async throws {
        let server = FakeFlaccyServer()
        let first = try makeDevice(server)
        let second = try makeDevice(server)
        server.newCode("SECOND")
        let song = try first.addTrack("A")
        try second.addTrack("A")
        _ = try await first.connect()
        _ = try await second.connect(code: "SECOND")
        let playlist = try XCTUnwrap(first.database.createPlaylist(name: "Mix").id)
        try first.database.addTrackToPlaylist(playlistId: playlist, trackFileURL: song.fileURL)
        assertUpToDate(await first.settle())
        assertUpToDate(await second.settle())
        XCTAssertEqual(try second.playlistTitles("Mix"), ["A"])
        try first.database.deletePlaylist(id: playlist)
        assertUpToDate(await first.settle())
        assertUpToDate(await second.settle())
        XCTAssertEqual(try second.playlistNames(), [])
        XCTAssertEqual(try second.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM playlistTracks") }, 0)
    }

    func testRemoteReorderAndRemovalsArriveInOrder() async throws {
        let server = FakeFlaccyServer()
        let first = try makeDevice(server)
        let second = try makeDevice(server)
        server.newCode("SECOND")
        let titles = ["A", "B", "C", "D"]
        let songs = try titles.map { try first.addTrack($0) }
        for title in titles { try second.addTrack(title) }
        _ = try await first.connect()
        _ = try await second.connect(code: "SECOND")
        let playlist = try XCTUnwrap(first.database.createPlaylist(name: "Mix").id)
        try first.database.addTracksToPlaylist(playlistId: playlist, trackFileURLs: songs.map(\.fileURL))
        assertUpToDate(await first.settle())
        assertUpToDate(await second.settle())

        let rows = try first.database.fetchPlaylistTracks(playlistId: playlist)
        let order = [rows[3], rows[0], rows[1], rows[2]]
        for (index, row) in order.enumerated() { try first.database.reorderPlaylistTrack(id: try XCTUnwrap(row.id), newPosition: index) }
        try first.database.removeTrackFromPlaylist(id: try XCTUnwrap(rows[1].id))
        assertUpToDate(await first.settle())
        assertUpToDate(await second.settle())
        XCTAssertEqual(try first.playlistTitles("Mix"), ["D", "A", "C"])
        XCTAssertEqual(try second.playlistTitles("Mix"), ["D", "A", "C"])
        XCTAssertEqual(server.titles(in: "Mix"), ["D", "A", "C"])
    }
}
