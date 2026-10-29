import FlaccyCore
import FlaccyServerCore
import Foundation
import GRDB
import XCTest

@testable import FlaccyEngine

final class ServerSyncImportTests: XCTestCase {

    private func args(_ device: SyncDevice, _ name: String) throws -> [ServerJSON] {
        try device.read { try String.fetchAll($0, sql: "SELECT args_json FROM sync_pending WHERE name = ? ORDER BY mutation_id", arguments: [name]) }
            .compactMap { ServerJSON(text: $0) }
    }

    func testTheFirstConnectDerivesIdsFromNamesSongsAndOccurrences() async throws {
        let device = try makeDevice(FakeFlaccyServer())
        let a = try device.addTrack("A")
        let b = try device.addTrack("B")
        try device.database.setLoved(fileURL: a.fileURL, loved: true, pendingOp: nil)
        let road = try XCTUnwrap(device.database.createPlaylist(name: "Road Trip").id)
        try device.database.addTracksToPlaylist(playlistId: road, trackFileURLs: [a.fileURL, b.fileURL, a.fileURL])
        let twin = try XCTUnwrap(device.database.createPlaylist(name: "road  trip").id)
        try device.database.addTrackToPlaylist(playlistId: twin, trackFileURL: b.fileURL)
        let cover = Data([0xFF, 0xD8, 0xFF, 0xE0, 9])
        try device.database.savePlaylistCover(cover, id: road)

        let connection = try await device.connect()
        XCTAssertEqual(connection.imported.playlists, 2)
        XCTAssertEqual(connection.imported.entries, 4)
        XCTAssertEqual(connection.imported.loves, 1)
        XCTAssertEqual(connection.imported.covers, 1)

        let expectedRoad = try ServerCore.playlistId(name: "Road Trip", occurrence: 0)
        let roadID = try device.read { try String.fetchOne($0, sql: "SELECT syncId FROM playlists WHERE id = ?", arguments: [road]) }
        let twinID = try device.read { try String.fetchOne($0, sql: "SELECT syncId FROM playlists WHERE id = ?", arguments: [twin]) }
        XCTAssertEqual(roadID, expectedRoad)
        XCTAssertNotEqual(twinID, try ServerCore.playlistId(name: "road trip", occurrence: 0))
        XCTAssertTrue(ServerSyncIDs.isUUID(try XCTUnwrap(twinID)))

        let keyA = try device.songKey("A")
        let keyB = try device.songKey("B")
        let entryIDs = try device.read { try String.fetchAll($0, sql: "SELECT syncId FROM playlistTracks WHERE playlistId = ? ORDER BY position, id", arguments: [road]) }
        XCTAssertEqual(entryIDs, [
            try ServerCore.entryId(playlistId: expectedRoad, songKey: keyA, occurrence: 0),
            try ServerCore.entryId(playlistId: expectedRoad, songKey: keyB, occurrence: 0),
            try ServerCore.entryId(playlistId: expectedRoad, songKey: keyA, occurrence: 1),
        ])

        let inserts = try args(device, "entry.insert").filter { $0["playlist"]?.string == expectedRoad }
        XCTAssertEqual(inserts.first?["place"]?["kind"]?.string, "last")
        XCTAssertEqual(inserts[1]["place"]?["kind"]?.string, "after")
        XCTAssertEqual(inserts[1]["place"]?["id"]?.string, entryIDs[0])
    }

    func testLovesAndCoversGoOutAtTheImportFloorSoAnyRealActionWins() async throws {
        let device = try makeDevice(FakeFlaccyServer())
        let a = try device.addTrack("A")
        try device.database.setLoved(fileURL: a.fileURL, loved: true, pendingOp: nil)
        let playlist = try XCTUnwrap(device.database.createPlaylist(name: "Mix").id)
        try device.database.savePlaylistCover(Data([0xFF, 0xD8, 1]), id: playlist)
        _ = try await device.connect()
        let floor: Int64 = 1_577_836_800_000 << 16
        let stamps = try device.read { db in
            try Row.fetchAll(db, sql: "SELECT name, stamp FROM sync_pending WHERE name IN ('love.set', 'playlist.setCover')")
                .map { ($0["name"] as String, $0["stamp"] as Int64) }
        }
        XCTAssertEqual(Set(stamps.map(\.0)), ["love.set", "playlist.setCover"])
        XCTAssertTrue(stamps.allSatisfy { $0.1 == floor })
        let create = try device.read { try Int64.fetchOne($0, sql: "SELECT stamp FROM sync_pending WHERE name = 'playlist.create'") }
        XCTAssertGreaterThan(try XCTUnwrap(create), floor)
    }

    func testTwoDevicesWithTheSamePlaylistDeriveTheSameIds() async throws {
        let server = FakeFlaccyServer()
        let first = try makeDevice(server)
        let second = try makeDevice(server)
        for device in [first, second] {
            let song = try device.addTrack("A")
            let playlist = try XCTUnwrap(device.database.createPlaylist(name: "Same").id)
            try device.database.addTrackToPlaylist(playlistId: playlist, trackFileURL: song.fileURL)
        }
        server.newCode("SECOND")
        _ = try await first.connect()
        _ = try await second.connect(code: "SECOND")
        let ids = try [first, second].map { device in
            try device.read { try String.fetchOne($0, sql: "SELECT syncId || '/' || (SELECT syncId FROM playlistTracks) FROM playlists") }
        }
        XCTAssertEqual(ids[0], ids[1])
    }

    func testEarlierPlaysGoOutAsMigratedListensInResumableChunksAndRepeatsAreHidden() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        let start: TimeInterval = 1_600_000_000
        try device.database.insertScrobbles((0..<1_203).map { index in
            ScrobbleRecord(
                trackTitle: "Song \(index % 40)", artist: "Artist", albumTitle: "Album",
                timestamp: Date(timeIntervalSince1970: start + Double(index) * 200), duration: index % 3 == 0 ? 0 : 180, submitted: true
            )
        })
        try device.database.insertScrobble(ScrobbleRecord(
            trackTitle: "Song 0", artist: "Artist", albumTitle: "Album", timestamp: Date(timeIntervalSince1970: start), duration: 0, submitted: true
        ))
        _ = try await device.connect()
        assertUpToDate(await device.engine.syncNow())
        let sizes = server.allPushes().flatMap(\.mutations).filter { $0.name == "listen.record" }
            .map { $0.args["listens"]?.array?.count ?? 0 }
        XCTAssertEqual(sizes, [300, 300, 300, 300, 3])
        let hidden = try device.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM scrobbles WHERE suppressed = 1") }
        XCTAssertEqual(hidden, 1)
        let withoutId = try device.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM scrobbles WHERE eventId IS NULL") }
        XCTAssertEqual(withoutId, 1)
        let first = try XCTUnwrap(server.allPushes().flatMap(\.mutations).first { $0.name == "listen.record" }?.args["listens"]?.array?.first)
        let expected = try ServerCore.eventIdsMig([(ts: Int64(start), titleKey: ListenHistory.titleKey("Song 0"), artistKey: ListenHistory.artistKey("Artist"))])
        XCTAssertEqual(first["eventId"]?.string, expected.first)
        XCTAssertEqual(first["recorded"]?.bool, false)
        XCTAssertEqual(try device.meta(SyncMeta.imported), "1")
        XCTAssertEqual(server.visiblePlays().count, 1_203)
    }

    func testReconnectingToTheSameServerFindsWhatIsAlreadyThereInsteadOfCreatingItTwice() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        let song = try device.addTrack("A")
        _ = try await device.connect()
        let playlist = try XCTUnwrap(device.database.createPlaylist(name: "Mix").id)
        try device.database.addTrackToPlaylist(playlistId: playlist, trackFileURL: song.fileURL)
        assertUpToDate(await device.engine.syncNow())
        try await device.engine.disconnect()

        server.newCode("AGAIN")
        _ = try await device.connect(code: "AGAIN")
        assertUpToDate(await device.engine.syncNow())
        let names = server.snapshot().playlists.values.map(\.playlist.name)
        XCTAssertEqual(names, ["Mix"])
        XCTAssertEqual(server.snapshot().playlists.values.first?.entries.filter(\.alive).count, 1)
        XCTAssertEqual(try device.playlistTitles("Mix"), ["A"])
    }
}
