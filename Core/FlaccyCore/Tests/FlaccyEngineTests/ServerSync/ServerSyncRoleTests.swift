import FlaccyCore
import FlaccyServerCore
import Foundation
import GRDB
import XCTest

@testable import FlaccyEngine

final class ServerSyncRoleTests: XCTestCase {

    private func library(_ device: SyncDevice) throws -> Int64 {
        let song = try device.addTrack("One")
        let playlist = try XCTUnwrap(device.database.createPlaylist(name: "Mine").id)
        try device.database.addTrackToPlaylist(playlistId: playlist, trackFileURL: song.fileURL)
        try device.database.setLoved(fileURL: song.fileURL, loved: true, pendingOp: nil)
        return playlist
    }

    func testAGuestConnectsButNothingIsQueuedOrSent() async throws {
        let server = FakeFlaccyServer()
        server.role = .guest
        let device = try makeDevice(server)
        _ = try library(device)
        let connection = try await device.connect()
        XCTAssertEqual(connection.role, .guest)
        let status = await device.engine.status
        XCTAssertEqual(status, .listenOnly(server: "Fake"))
        XCTAssertTrue(device.database.serverSyncGate.isConfigured)
        XCTAssertFalse(device.database.serverSyncGate.isRecording)
        XCTAssertFalse(device.tokens.isEmpty)

        _ = try device.database.createPlaylist(name: "After")
        try device.play("One", at: 1_000)
        XCTAssertEqual(try device.pendingNames(), [])
        XCTAssertEqual(try device.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM playlists WHERE syncId IS NOT NULL") }, 0)
        XCTAssertEqual(try device.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM scrobbles WHERE eventId IS NOT NULL") }, 0)

        let after = await device.settle()
        XCTAssertEqual(after, .listenOnly(server: "Fake"))
        XCTAssertEqual(server.callCount("push"), 0)
        XCTAssertEqual(server.callCount("pull"), 0)
        XCTAssertEqual(try device.playlistNames(), ["After", "Mine"])
    }

    func testAPendingDeviceWaitsForApprovalWithoutQueueingAnything() async throws {
        let server = FakeFlaccyServer()
        server.role = .pending
        let device = try makeDevice(server)
        _ = try library(device)
        let connection = try await device.connect()
        XCTAssertEqual(connection.role, .pending)
        let status = await device.settle()
        XCTAssertEqual(status, .awaitingApproval(server: "Fake"))
        XCTAssertFalse(device.database.serverSyncGate.isRecording)
        XCTAssertEqual(try device.pendingNames(), [])
        XCTAssertEqual(server.callCount("push") + server.callCount("pull") + server.callCount("listens"), 0)
    }

    func testApprovalImportsWhatTheLibraryHoldsAndStartsSyncing() async throws {
        let server = FakeFlaccyServer()
        server.role = .pending
        let device = try makeDevice(server)
        _ = try library(device)
        _ = try await device.connect()
        _ = await device.settle()
        _ = try device.database.createPlaylist(name: "While waiting")

        server.role = .member
        assertUpToDate(await device.settle())
        XCTAssertTrue(device.database.serverSyncGate.isRecording)
        XCTAssertEqual(Set(server.snapshot().playlists.values.map(\.playlist.name)), ["Mine", "While waiting"])
        XCTAssertEqual(server.titles(in: "Mine"), ["One"])
        XCTAssertEqual(server.snapshot().loves.values.filter(\.loved).count, 1)
        let pending = await device.engine.pendingChangeCount()
        XCTAssertEqual(pending, 0)
    }

    func testLosingTheRightToWriteKeepsEveryPendingWriteAndEveryLocalPlaylist() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        let mine = try library(device)
        _ = try await device.connect()
        assertUpToDate(await device.settle())
        try device.database.renamePlaylist(id: mine, name: "Renamed")
        _ = try device.database.createPlaylist(name: "Second")
        let queued = try device.pendingNames()
        XCTAssertEqual(queued, ["playlist.rename", "playlist.create"])
        let pushesBefore = server.allPushes().count

        server.role = .guest
        let status = await device.settle()
        XCTAssertEqual(status, .listenOnly(server: "Fake"))
        XCTAssertEqual(server.allPushes().count, pushesBefore)
        XCTAssertEqual(try device.pendingNames(), queued)
        XCTAssertEqual(try device.pendingRows().map(\.failed), [false, false])
        XCTAssertEqual(try device.playlistNames(), ["Renamed", "Second"])

        _ = try device.database.createPlaylist(name: "Third")
        XCTAssertEqual(try device.pendingNames().count, 3)

        server.role = .member
        assertUpToDate(await device.settle())
        XCTAssertEqual(Set(server.snapshot().playlists.values.map(\.playlist.name)), ["Renamed", "Second", "Third"])
        XCTAssertEqual(try device.playlistNames(), ["Renamed", "Second", "Third"])
        let pending = await device.engine.pendingChangeCount()
        XCTAssertEqual(pending, 0)
    }

    func testAWriteRefusedBecauseTheRightWasJustLostStaysQueuedAndIsSentUnderNewIds() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        _ = try device.database.createPlaylist(name: "Mine")
        let instanceBefore = try device.meta(SyncMeta.instance)

        server.queuedHelloRoles = [.member, .guest]
        server.writeRole = .guest
        let status = await device.settle()
        XCTAssertEqual(status, .listenOnly(server: "Fake"))
        XCTAssertEqual(try device.playlistNames(), ["Mine"])
        XCTAssertEqual(try device.pendingNames(), ["playlist.create"])
        XCTAssertEqual(try device.pendingRows().map(\.failed), [false])
        XCTAssertEqual(try device.pendingRows().map(\.acked), [false])
        XCTAssertNotEqual(try device.meta(SyncMeta.instance), instanceBefore)
        XCTAssertEqual(try device.pendingRows().map(\.id), [1])

        server.writeRole = .member
        server.role = .member
        assertUpToDate(await device.settle())
        XCTAssertEqual(server.snapshot().playlists.values.map(\.playlist.name), ["Mine"])
        XCTAssertEqual(try device.playlistNames(), ["Mine"])
    }

    func testARefusalForAWriterIsStillAFailureThatDropsTheWrite() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try await device.connect()
        _ = try device.database.createPlaylist(name: "Mine")
        server.writeRole = .guest
        _ = await device.settle()
        XCTAssertEqual(try device.playlistNames(), [])
    }
}
