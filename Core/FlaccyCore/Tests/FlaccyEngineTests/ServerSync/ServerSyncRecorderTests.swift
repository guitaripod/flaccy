import FlaccyCore
import FlaccyServerCore
import Foundation
import GRDB
import XCTest

@testable import FlaccyEngine

final class ServerSyncRecorderTests: XCTestCase {

    func testMigrationAddsTheSyncTablesAndColumns() throws {
        let device = try makeDevice(FakeFlaccyServer())
        let tables = try device.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'sync_%'") }
        XCTAssertEqual(Set(tables), ["sync_meta", "sync_base", "sync_pending", "sync_ghosts", "sync_blobs", "sync_song_keys"])
        let scrobbleColumns = try device.read { try String.fetchAll($0, sql: "SELECT name FROM pragma_table_info('scrobbles')") }
        XCTAssertTrue(scrobbleColumns.contains("eventId") && scrobbleColumns.contains("suppressed"))
        let playlistColumns = try device.read { try String.fetchAll($0, sql: "SELECT name FROM pragma_table_info('playlistTracks')") }
        XCTAssertTrue(playlistColumns.contains("syncId"))
        let indexes = try device.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE '%syncId' OR name LIKE '%eventId'") }
        XCTAssertEqual(Set(indexes), ["playlists_on_syncId", "playlistTracks_on_syncId", "scrobbles_on_eventId"])
    }

    func testWritesRecordNothingWithoutAServer() throws {
        let device = try makeDevice(FakeFlaccyServer())
        let song = try device.addTrack("One")
        let playlist = try XCTUnwrap(device.database.createPlaylist(name: "Mix").id)
        try device.database.addTrackToPlaylist(playlistId: playlist, trackFileURL: song.fileURL)
        try device.database.setLoved(fileURL: song.fileURL, loved: true, pendingOp: nil)
        try device.play("One", at: 1_000)
        XCTAssertFalse(device.database.serverSyncGate.isConfigured)
        XCTAssertEqual(try device.pendingNames(), [])
        let syncIDs = try device.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM playlists WHERE syncId IS NOT NULL") }
        XCTAssertEqual(syncIDs, 0)
        let eventIDs = try device.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM scrobbles WHERE eventId IS NOT NULL") }
        XCTAssertEqual(eventIDs, 0)
    }

    func testPlaylistWritesBecomeMutationsWithDenseIdsAndRisingStamps() async throws {
        let device = try makeDevice(FakeFlaccyServer())
        let first = try device.addTrack("One")
        let second = try device.addTrack("Two")
        _ = try await device.connect()
        let playlist = try XCTUnwrap(device.database.createPlaylist(name: "Mix").id)
        try device.database.addTrackToPlaylist(playlistId: playlist, trackFileURL: first.fileURL)
        try device.database.addTracksToPlaylist(playlistId: playlist, trackFileURLs: [second.fileURL, first.fileURL])
        try device.database.renamePlaylist(id: playlist, name: "Renamed")
        let row = try XCTUnwrap(device.database.fetchPlaylistTracks(playlistId: playlist).first?.id)
        try device.database.removeTrackFromPlaylist(id: row)
        try device.database.deletePlaylist(id: playlist)
        XCTAssertEqual(
            try device.pendingNames(),
            ["playlist.create", "entry.insert", "entry.insertMany", "playlist.rename", "entry.remove", "playlist.delete"]
        )
        let stamps = try device.read { try Int64.fetchAll($0, sql: "SELECT stamp FROM sync_pending ORDER BY mutation_id") }
        XCTAssertEqual(stamps, stamps.sorted())
        XCTAssertEqual(Set(stamps).count, stamps.count)
        let ids = try device.read { try Int64.fetchAll($0, sql: "SELECT mutation_id FROM sync_pending ORDER BY mutation_id") }
        XCTAssertEqual(ids, Array(1...Int64(ids.count)))
        let create = try device.read { try String.fetchOne($0, sql: "SELECT args_json FROM sync_pending WHERE name = 'playlist.create'") }
        let args = try XCTUnwrap(ServerJSON(text: try XCTUnwrap(create)))
        XCTAssertTrue(ServerSyncIDs.isUUID(try XCTUnwrap(args["id"]?.string)))
        XCTAssertEqual(args["name"]?.string, "Mix")
    }

    func testRenameKeepsTheRowItsTracksAndItsIdentity() async throws {
        let device = try makeDevice(FakeFlaccyServer())
        let song = try device.addTrack("One")
        _ = try await device.connect()
        let playlist = try XCTUnwrap(device.database.createPlaylist(name: "Mix").id)
        try device.database.addTrackToPlaylist(playlistId: playlist, trackFileURL: song.fileURL)
        let syncID = try device.read { try String.fetchOne($0, sql: "SELECT syncId FROM playlists WHERE id = ?", arguments: [playlist]) }
        try device.database.renamePlaylist(id: playlist, name: "Better")
        XCTAssertEqual(try device.playlistTitles("Better"), ["One"])
        let after = try device.read { try String.fetchOne($0, sql: "SELECT syncId FROM playlists WHERE id = ?", arguments: [playlist]) }
        XCTAssertEqual(after, syncID)
    }

    func testAMoveIsQueuedOnlyWhenAnEntrysNeighbourChanged() async throws {
        let device = try makeDevice(FakeFlaccyServer())
        let songs = try ["A", "B", "C", "D", "E"].map { try device.addTrack($0) }
        _ = try await device.connect()
        let playlist = try XCTUnwrap(device.database.createPlaylist(name: "Mix").id)
        try device.database.addTracksToPlaylist(playlistId: playlist, trackFileURLs: songs.map(\.fileURL))
        let rows = try device.database.fetchPlaylistTracks(playlistId: playlist)
        let before = try device.pendingNames().count
        let reordered = [rows[2], rows[0], rows[1], rows[3], rows[4]]
        for (index, row) in reordered.enumerated() {
            try device.database.reorderPlaylistTrack(id: try XCTUnwrap(row.id), newPosition: index)
        }
        let moves = try device.pendingNames().dropFirst(before)
        XCTAssertFalse(moves.isEmpty)
        XCTAssertTrue(moves.allSatisfy { $0 == "entry.move" })
        XCTAssertLessThanOrEqual(moves.count, 2)
        XCTAssertEqual(try device.playlistTitles("Mix"), ["C", "A", "B", "D", "E"])

        let unchanged = try device.pendingNames().count
        for (index, row) in reordered.enumerated() {
            try device.database.reorderPlaylistTrack(id: try XCTUnwrap(row.id), newPosition: index)
        }
        XCTAssertEqual(try device.pendingNames().count, unchanged)
    }

    func testPlaysCoalesceIntoOneBatchUntilItHasBeenSent() async throws {
        let device = try makeDevice(FakeFlaccyServer())
        _ = try await device.connect()
        for index in 0..<3 { try device.play("Song \(index)", at: 10_000 + Double(index) * 300) }
        XCTAssertEqual(try device.pendingNames(), ["listen.record"])
        let args = try device.read { try String.fetchOne($0, sql: "SELECT args_json FROM sync_pending") }
        let listens = try XCTUnwrap(ServerJSON(text: try XCTUnwrap(args))?["listens"]?.array)
        XCTAssertEqual(listens.count, 3)
        XCTAssertEqual(Set(listens.compactMap { $0["eventId"]?.string }).count, 3)
        XCTAssertTrue(listens.allSatisfy { ServerScalarRules.isSongKey($0["ref"]?["songKey"]?.string ?? "") })

        _ = try device.write { try SyncPending.nextBatch($0, maxCount: 500, maxBytes: 900_000) }
        try device.play("Song 3", at: 20_000)
        XCTAssertEqual(try device.pendingNames(), ["listen.record", "listen.record"])
    }

    func testLovesAreRecordedOnlyWhenTheStateReallyChanges() async throws {
        let device = try makeDevice(FakeFlaccyServer())
        let song = try device.addTrack("One")
        let other = try device.addTrack("Two")
        _ = try await device.connect()
        try device.database.setLoved(fileURL: song.fileURL, loved: false, pendingOp: nil)
        XCTAssertEqual(try device.pendingNames(), [])
        try device.database.setLoved(fileURL: song.fileURL, loved: true, pendingOp: nil)
        try device.database.setLoved(fileURL: song.fileURL, loved: true, pendingOp: nil)
        try device.database.markLoved(paths: [song.fileURL, other.fileURL], loved: true)
        XCTAssertEqual(try device.pendingNames(), ["love.set", "love.set"])
        let args = try device.read { try String.fetchAll($0, sql: "SELECT args_json FROM sync_pending ORDER BY mutation_id") }
        XCTAssertEqual(ServerJSON(text: args[0])?["songKey"]?.string, try device.songKey("One"))
        XCTAssertEqual(ServerJSON(text: args[1])?["songKey"]?.string, try device.songKey("Two"))
    }

    func testALyricsOffsetBecomesAScalarKeyedBySongAndNegativeOnesStayHome() async throws {
        let device = try makeDevice(FakeFlaccyServer())
        try device.database.saveLyrics(LyricsRecord(trackTitle: "One", artist: "Artist", instrumental: false))
        _ = try await device.connect()
        try device.database.saveLyricsOffset(trackTitle: "One", artist: "Artist", offsetMs: 250)
        try device.database.saveLyricsOffset(trackTitle: "One", artist: "Artist", offsetMs: -250)
        XCTAssertEqual(try device.pendingNames(), ["scalar.set"])
        let args = try device.read { try String.fetchOne($0, sql: "SELECT args_json FROM sync_pending") }
        let decoded = try XCTUnwrap(ServerJSON(text: try XCTUnwrap(args)))
        XCTAssertEqual(decoded["key"]?.string, "lyr/" + (try device.songKey("One")))
        XCTAssertEqual(decoded["value"]?.int, 250)
    }

    func testCoversAreStoredAsBlobsAndQueuedByHash() async throws {
        let device = try makeDevice(FakeFlaccyServer())
        _ = try await device.connect()
        let playlist = try XCTUnwrap(device.database.createPlaylist(name: "Mix").id)
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        try device.database.savePlaylistCover(image, id: playlist)
        let args = try device.read { try String.fetchOne($0, sql: "SELECT args_json FROM sync_pending WHERE name = 'playlist.setCover'") }
        let hash = try XCTUnwrap(ServerJSON(text: try XCTUnwrap(args))?["blob"]?.string)
        XCTAssertEqual(hash, SyncMaterializer.hexDigest(image))
        XCTAssertEqual(try device.read { try Data.fetchOne($0, sql: "SELECT data FROM sync_blobs WHERE hash = ?", arguments: [hash]) }, image)
        try device.database.clearPlaylistCover(id: playlist)
        XCTAssertEqual(try device.pendingNames().last, "playlist.clearCover")
    }

    func testSuppressedPlaysAreLeftOutOfEveryCountAndList() throws {
        let device = try makeDevice(FakeFlaccyServer())
        try device.play("Loud", at: 1_700_000_000)
        try device.play("Loud", at: 1_700_000_100)
        try device.play("Hidden", at: 1_700_000_200)
        try device.write { try $0.execute(sql: "UPDATE scrobbles SET suppressed = 1 WHERE trackTitle = 'Hidden'") }
        let database = device.database
        XCTAssertEqual(try database.scrobbleCount(submittedOnly: false), 2)
        XCTAssertEqual(try database.fetchAllScrobbleRows().count, 2)
        XCTAssertEqual(try database.playCountByTrack().map(\.count), [2])
        XCTAssertEqual(try database.scrobbleCountInRange(from: .distantPast, to: .distantFuture), 2)
        XCTAssertEqual(try database.scrobbleTotals(from: .distantPast, to: .distantFuture).plays, 2)
        XCTAssertEqual(try database.scrobbleTotals(from: Date(timeIntervalSince1970: 1_699_999_000), to: Date(timeIntervalSince1970: 1_700_001_000)).plays, 2)
        XCTAssertEqual(try database.scrobbleTopTracks(from: .distantPast, to: .distantFuture, limit: 10).map(\.title), ["Loud"])
        XCTAssertEqual(try database.scrobbleQuarterHourCounts(from: .distantPast, to: .distantFuture).map(\.count).reduce(0, +), 2)
        XCTAssertEqual(try database.lastPlayedByAlbum().map(\.playCount), [2])
        XCTAssertEqual(try database.fetchScrobbleRows(from: .distantPast, to: .distantFuture).count, 2)
        XCTAssertEqual(try database.fetchPendingScrobbles().count, 0)
    }
}
