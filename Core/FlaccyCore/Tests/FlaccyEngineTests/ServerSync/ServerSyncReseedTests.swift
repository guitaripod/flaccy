import FlaccyCore
import FlaccyServerCore
import Foundation
import GRDB
import XCTest

@testable import FlaccyEngine

final class ServerSyncReseedTests: XCTestCase {

    private func emptied(_ server: FakeFlaccyServer) -> FakeFlaccyServer.State {
        var empty = server.snapshot()
        empty.rows = [:]
        empty.playlists = [:]
        empty.loves = [:]
        empty.scalars = [:]
        empty.plays = [:]
        empty.progress = [:]
        empty.results = [:]
        empty.blobs = [:]
        return empty
    }

    private func padded(_ index: Int) throws -> ServerSongRef {
        var song = try ServerSongIdentity.ref(title: "Song \(index)", artist: "Artist \(index % 50)", album: String(repeating: "a", count: 480))
        song.relPath = "Artist/\(index).flac"
        return song
    }

    private func reseeds(_ server: FakeFlaccyServer, after count: Int) -> [ServerMutation] {
        server.allPushes().dropFirst(count).flatMap(\.mutations).filter { $0.name == "state.reseed" }
    }

    func testABaseOf5000EntitiesAnd3MegabytesIsReseededInChunksTheServerAccepts() async throws {
        let server = FakeFlaccyServer()
        for playlist in 0..<40 {
            try server.plantPlaylist(name: "Playlist \(playlist)", songs: try (0..<50).map { try padded(playlist * 50 + $0) })
        }
        for index in 0..<3_000 {
            try server.plantLove(try padded(10_000 + index), loved: true, stamp: Int64(index + 1) << 16)
        }
        let device = try makeDevice(server)
        _ = try await device.connect()
        assertUpToDate(await device.settle())
        let baseEntities = try device.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_base WHERE kind IN ('playlist', 'playlist_entry', 'love')") }
        XCTAssertEqual(baseEntities, 5_040)

        server.restore(emptied(server), newIncarnation: true)
        let pushesBefore = server.allPushes().count
        assertUpToDate(await device.settle())

        let sent = reseeds(server, after: pushesBefore)
        let entityLists = sent.map { $0.args["entities"]?.array ?? [] }
        XCTAssertTrue(entityLists.allSatisfy { $0.count <= 1_000 })
        XCTAssertTrue(sent.allSatisfy { ($0.args.text?.utf8.count ?? 0) <= 400_000 })
        XCTAssertEqual(entityLists.map(\.count).reduce(0, +), 5_040)
        XCTAssertGreaterThanOrEqual(sent.count, 9)
        XCTAssertGreaterThan(sent.map { $0.args.text?.utf8.count ?? 0 }.reduce(0, +), 3_000_000)

        var seenPlaylists = Set<String>()
        for entity in entityLists.joined() {
            if entity["kind"]?.string == "playlist", let id = entity["id"]?.string { seenPlaylists.insert(id) }
            if entity["kind"]?.string == "playlist_entry", let playlist = entity["value"]?["playlist"]?.string {
                XCTAssertTrue(seenPlaylists.contains(playlist), "an entry was sent before its playlist")
            }
        }
        XCTAssertEqual(server.snapshot().playlists.count, 40)
        XCTAssertEqual(server.snapshot().playlists.values.map { $0.entries.count }.reduce(0, +), 2_000)
        XCTAssertEqual(server.snapshot().loves.count, 3_000)
        let pending = await device.engine.pendingChangeCount()
        XCTAssertEqual(pending, 0)
    }

    func testAReseededCoverIsUploadedBeforeTheReseedNamesIt() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        let playlist = try XCTUnwrap(device.database.createPlaylist(name: "Mix").id)
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 4, 5, 6])
        try device.database.savePlaylistCover(image, id: playlist)
        assertUpToDate(await device.settle())

        server.restore(emptied(server), newIncarnation: true)
        let callsBefore = server.calls.count
        assertUpToDate(await device.settle())
        let later = Array(server.calls.dropFirst(callsBefore))
        let upload = try XCTUnwrap(later.firstIndex(of: "putBlob"))
        let push = try XCTUnwrap(later.firstIndex(of: "push"))
        XCTAssertLessThan(upload, push)
        let hash = SyncMaterializer.hexDigest(image)
        XCTAssertEqual(server.snapshot().playlists.values.first?.playlist.coverBlob, hash)
        XCTAssertEqual(server.snapshot().blobs[hash], image)
    }

    func testARefusedCoverIsUploadedAgainFromTheLocalCopyOnce() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        let playlist = try XCTUnwrap(device.database.createPlaylist(name: "Mix").id)
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 7, 8])
        try device.database.savePlaylistCover(image, id: playlist)
        assertUpToDate(await device.settle())

        server.restore(emptied(server), newIncarnation: true)
        server.refuseCoversTimes = 1
        let pushesBefore = server.allPushes().count
        let uploadsBefore = server.callCount("putBlob")
        assertUpToDate(await device.settle())
        XCTAssertEqual(reseeds(server, after: pushesBefore).count, 2)
        XCTAssertGreaterThanOrEqual(server.callCount("putBlob") - uploadsBefore, 2)
        XCTAssertEqual(server.snapshot().playlists.values.first?.playlist.coverBlob, SyncMaterializer.hexDigest(image))
        XCTAssertEqual(try device.playlistNames(), ["Mix"])
    }

    func testCoversTheServerKeepsRefusingAreLeftOutSoTheRestOfTheBaseStillArrives() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        let song = try device.addTrack("One")
        _ = try await device.connect()
        let playlist = try XCTUnwrap(device.database.createPlaylist(name: "Mix").id)
        try device.database.addTrackToPlaylist(playlistId: playlist, trackFileURL: song.fileURL)
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 1])
        try device.database.savePlaylistCover(image, id: playlist)
        assertUpToDate(await device.settle())

        server.restore(emptied(server), newIncarnation: true)
        server.refuseCoversTimes = 99
        assertUpToDate(await device.settle())
        XCTAssertEqual(server.titles(in: "Mix"), ["One"])
        XCTAssertNil(server.playlist(named: "Mix")?.playlist.coverBlob)
        XCTAssertEqual(try device.database.playlistCover(id: playlist), image)
        XCTAssertEqual(try device.playlistTitles("Mix"), ["One"])
        XCTAssertNil(try device.meta(SyncMeta.reseedCoverRetry))
        let pending = await device.engine.pendingChangeCount()
        XCTAssertEqual(pending, 0)
    }

    func testACoverThisDeviceNeverFetchedIsNotNamedByTheReseed() async throws {
        let server = FakeFlaccyServer()
        try server.plantPlaylist(name: "Theirs", songs: [], coverBlob: String(repeating: "c", count: 64))
        let device = try makeDevice(server)
        _ = try await device.connect()
        assertUpToDate(await device.settle())
        XCTAssertEqual(try device.playlistNames(), ["Theirs"])

        server.restore(emptied(server), newIncarnation: true)
        let pushesBefore = server.allPushes().count
        assertUpToDate(await device.settle())
        XCTAssertEqual(reseeds(server, after: pushesBefore).count, 1)
        XCTAssertEqual(server.snapshot().playlists.count, 1)
        XCTAssertNil(server.playlist(named: "Theirs")?.playlist.coverBlob)
    }
}
