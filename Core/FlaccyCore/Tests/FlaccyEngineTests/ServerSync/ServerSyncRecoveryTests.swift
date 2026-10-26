import FlaccyCore
import FlaccyServerCore
import Foundation
import GRDB
import XCTest

@testable import FlaccyEngine

final class ServerSyncRecoveryTests: XCTestCase {

    private func seeded(_ server: FakeFlaccyServer) async throws -> (SyncDevice, TrackRecord) {
        let device = try makeDevice(server)
        let song = try device.addTrack("One")
        _ = try await device.connect()
        let playlist = try XCTUnwrap(device.database.createPlaylist(name: "Mix").id)
        try device.database.addTrackToPlaylist(playlistId: playlist, trackFileURL: song.fileURL)
        try device.database.setLoved(fileURL: song.fileURL, loved: true, pendingOp: nil)
        try device.play("One", at: Date().timeIntervalSince1970 - 5_000)
        assertUpToDate(await device.settle())
        return (device, song)
    }

    func testAServerThatLostItsProgressMakesTheClientRebuildItFromItsBase() async throws {
        let server = FakeFlaccyServer()
        let (device, _) = try await seeded(server)
        let instanceBefore = try device.meta(SyncMeta.instance)
        server.forgetProgress()
        _ = try device.database.createPlaylist(name: "Second")
        assertUpToDate(await device.settle())
        XCTAssertNotEqual(try device.meta(SyncMeta.instance), instanceBefore)
        XCTAssertEqual(Set(server.snapshot().playlists.values.map(\.playlist.name)), ["Mix", "Second"])
        XCTAssertEqual(server.titles(in: "Mix"), ["One"])
        let pending = await device.engine.pendingChangeCount()
        XCTAssertEqual(pending, 0)
    }

    func testAnInstanceConflictMovesTheQueueToANewInstanceAndRenumbersIt() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        _ = try device.database.createPlaylist(name: "First")
        _ = try device.database.createPlaylist(name: "Second")
        let link = try XCTUnwrap(ServerSyncStore(database: device.database).link())
        server.locked {
            server.state.results["\(link.device)|\(link.instance)|1"] = ("a different history", ServerMutationResult(id: 1, status: .applied))
            server.state.progress["\(link.device)|\(link.instance)"] = 1
        }
        assertUpToDate(await device.settle())
        let after = try XCTUnwrap(ServerSyncStore(database: device.database).link())
        XCTAssertNotEqual(after.instance, link.instance)
        XCTAssertEqual(Set(server.snapshot().playlists.values.map(\.playlist.name)), ["First", "Second"])
        XCTAssertEqual(server.allPushes().last?.mutations.map(\.id), [1, 2])
    }

    func testARestoredServerWithANewIncarnationGetsEverythingBackFromTheClientsBase() async throws {
        let server = FakeFlaccyServer()
        let (device, song) = try await seeded(server)
        var empty = server.snapshot()
        empty.rows = [:]
        empty.playlists = [:]
        empty.loves = [:]
        empty.plays = [:]
        empty.progress = [:]
        empty.results = [:]
        server.restore(empty, newIncarnation: true)
        assertUpToDate(await device.settle())
        XCTAssertEqual(server.titles(in: "Mix"), ["One"])
        XCTAssertEqual(server.snapshot().loves.values.filter(\.loved).count, 1)
        XCTAssertEqual(server.visiblePlays().count, 1)
        XCTAssertEqual(try device.meta(SyncMeta.incarnation), server.incarnation)
        XCTAssertEqual(try device.playlistTitles("Mix"), ["One"])
        XCTAssertTrue(try device.isLoved(song.fileURL))
        let pending = await device.engine.pendingChangeCount()
        XCTAssertEqual(pending, 0)
    }

    func testACursorAheadOfARestoredServerResetsLikeANewIncarnation() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        let song = try device.addTrack("One")
        _ = try await device.connect()
        _ = try device.database.createPlaylist(name: "First")
        assertUpToDate(await device.settle())
        let older = server.snapshot()
        let second = try XCTUnwrap(device.database.createPlaylist(name: "Second").id)
        try device.database.addTrackToPlaylist(playlistId: second, trackFileURL: song.fileURL)
        assertUpToDate(await device.settle())
        XCTAssertGreaterThan(server.seq, older.seq)
        server.restore(older, newIncarnation: false)
        assertUpToDate(await device.settle())
        XCTAssertEqual(Set(server.snapshot().playlists.values.map(\.playlist.name)), ["First", "Second"])
        XCTAssertEqual(server.titles(in: "Second"), ["One"])
    }

    func testAMutationTheServerRefusedDropsOutOfTheVisibleStateAtOnce() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        let playlist = try XCTUnwrap(device.database.createPlaylist(name: "Old").id)
        assertUpToDate(await device.settle())
        server.refusedNames = ["playlist.rename"]
        try device.database.renamePlaylist(id: playlist, name: "New")
        XCTAssertEqual(try device.playlistNames(), ["New"])
        let store = ServerSyncStore(database: device.database)
        let request = try XCTUnwrap(store.nextPush())
        let response = try await server.transport(token: device.tokens.token(serverID: "fake:4545"))
            .push(request, incarnation: server.incarnation)
        XCTAssertEqual(response.results.first?.status, .invalid)
        let outcome = try store.onPushResponse(instance: request.instance, response: response, localNowMs: 0)
        XCTAssertTrue(outcome.changes.playlists)
        XCTAssertEqual(try device.playlistNames(), ["Old"])
        XCTAssertEqual(try device.pendingRows().map(\.failed), [true])
        assertUpToDate(await device.settle())
        XCTAssertEqual(try device.playlistNames(), ["Old"])
        let pending = await device.engine.pendingChangeCount()
        XCTAssertEqual(pending, 0)
    }

    func testTheNewestStampWinsAndTheOlderEditIsFoldedAwayOnceThePullShowsTheNewerOne() async throws {
        let server = FakeFlaccyServer()
        let first = try makeDevice(server)
        let second = try makeDevice(server)
        server.newCode("SECOND")
        _ = try await first.connect()
        _ = try await second.connect(code: "SECOND")
        let playlist = try XCTUnwrap(first.database.createPlaylist(name: "Mix").id)
        assertUpToDate(await first.settle())
        assertUpToDate(await second.settle())
        let secondPlaylist = try second.playlistID("Mix")

        try second.database.renamePlaylist(id: secondPlaylist, name: "Older edit")
        try await Task.sleep(for: .milliseconds(30))
        try first.database.renamePlaylist(id: playlist, name: "Newer edit")
        assertUpToDate(await first.settle())
        XCTAssertEqual(try second.playlistNames(), ["Older edit"])
        assertUpToDate(await second.settle())
        XCTAssertEqual(try second.playlistNames(), ["Newer edit"])
        assertUpToDate(await first.settle())
        XCTAssertEqual(try first.playlistNames(), ["Newer edit"])
        XCTAssertEqual(server.snapshot().playlists.values.map(\.playlist.name), ["Newer edit"])
    }

    func testTwoDevicesThatConnectWithTheSameNamedPlaylistEndWithOneMergedPlaylist() async throws {
        let server = FakeFlaccyServer()
        let first = try makeDevice(server)
        let second = try makeDevice(server)
        server.newCode("SECOND")
        let x = try first.addTrack("X")
        let y = try first.addTrack("Y")
        let road = try XCTUnwrap(first.database.createPlaylist(name: "Road Trip").id)
        try first.database.addTracksToPlaylist(playlistId: road, trackFileURLs: [x.fileURL, y.fileURL])
        try first.database.setLoved(fileURL: x.fileURL, loved: true, pendingOp: nil)
        try second.addTrack("X")
        let y2 = try second.addTrack("Y")
        let z = try second.addTrack("Z")
        let other = try XCTUnwrap(second.database.createPlaylist(name: "  road trip ").id)
        try second.database.addTracksToPlaylist(playlistId: other, trackFileURLs: [y2.fileURL, z.fileURL])
        try second.database.setLoved(fileURL: z.fileURL, loved: true, pendingOp: nil)

        _ = try await first.connect()
        _ = try await second.connect(code: "SECOND")
        assertUpToDate(await first.settle())
        assertUpToDate(await second.settle())
        assertUpToDate(await first.settle())

        XCTAssertEqual(server.snapshot().playlists.count, 1)
        XCTAssertEqual(server.titles(in: "Road Trip"), ["X", "Y", "Z"])
        XCTAssertEqual(try first.playlistTitles("Road Trip"), ["X", "Y"])
        XCTAssertEqual(try second.playlistNames(), ["Road Trip"])
        XCTAssertEqual(try second.playlistTitles("Road Trip"), ["X", "Y", "Z"])
        XCTAssertEqual(server.snapshot().loves.values.filter(\.loved).count, 2)
    }
}
