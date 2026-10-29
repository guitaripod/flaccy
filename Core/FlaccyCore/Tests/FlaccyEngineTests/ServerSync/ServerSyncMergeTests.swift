import FlaccyCore
import Foundation
import XCTest

@testable import FlaccyEngine

final class ServerSyncMergeTests: XCTestCase {

    private func makePhoneAndLaptop() async throws -> (phone: SyncDevice, laptop: SyncDevice, server: FakeFlaccyServer) {
        let server = FakeFlaccyServer()
        let laptop = try makeDevice(server)
        let phone = try makeDevice(server)
        server.newCode("PHONE")
        for title in ["One", "Two", "Three", "Four"] {
            try laptop.addTrack(title)
            try phone.addTrack(title)
        }
        return (phone, laptop, server)
    }

    func testThePlaylistsOnBothSidesTheLovesAndThePlaysTheServerBroughtAreWhatMerged() async throws {
        let (phone, laptop, _) = try await makePhoneAndLaptop()
        let laptopPlaylist = try XCTUnwrap(laptop.database.createPlaylist(name: "Road Trip").id)
        try laptop.database.addTracksToPlaylist(playlistId: laptopPlaylist, trackFileURLs: ["Artist/Album/One.flac"])
        let workout = try XCTUnwrap(laptop.database.createPlaylist(name: "Workout").id)
        try laptop.database.addTracksToPlaylist(playlistId: workout, trackFileURLs: ["Artist/Album/Two.flac"])
        _ = try laptop.database.createPlaylist(name: "Only On The Laptop")
        try laptop.database.setLoved(fileURL: "Artist/Album/Two.flac", loved: true, pendingOp: nil)
        try laptop.database.setLoved(fileURL: "Artist/Album/Three.flac", loved: true, pendingOp: nil)
        try laptop.play("One", at: 1_700_000_000)
        try laptop.play("Two", at: 1_700_000_300)
        _ = try await laptop.connect()
        assertUpToDate(await laptop.settle())

        let phoneRoadTrip = try XCTUnwrap(phone.database.createPlaylist(name: "Road Trip").id)
        try phone.database.addTracksToPlaylist(playlistId: phoneRoadTrip, trackFileURLs: ["Artist/Album/Four.flac"])
        let phoneWorkout = try XCTUnwrap(phone.database.createPlaylist(name: "Workout").id)
        try phone.database.addTracksToPlaylist(playlistId: phoneWorkout, trackFileURLs: ["Artist/Album/Four.flac"])
        _ = try phone.database.createPlaylist(name: "Only On The Phone")
        try phone.database.setLoved(fileURL: "Artist/Album/Four.flac", loved: true, pendingOp: nil)
        _ = try await phone.connect(code: "PHONE")
        assertUpToDate(await phone.settle())

        let report = await phone.engine.firstConnectMerge()

        XCTAssertEqual(report.playlistNames, ["Road Trip", "Workout"])
        XCTAssertEqual(report.lovesAdded, 2)
        XCTAssertEqual(report.listensMerged, 2)
        XCTAssertFalse(report.isEmpty)
    }

    func testTheReportIsGivenOnceAndThenForgotten() async throws {
        let (phone, laptop, _) = try await makePhoneAndLaptop()
        try laptop.database.setLoved(fileURL: "Artist/Album/One.flac", loved: true, pendingOp: nil)
        _ = try await laptop.connect()
        assertUpToDate(await laptop.settle())
        _ = try await phone.connect(code: "PHONE")
        assertUpToDate(await phone.settle())

        let first = await phone.engine.firstConnectMerge()
        let second = await phone.engine.firstConnectMerge()

        XCTAssertEqual(first.lovesAdded, 1)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(second, ServerMergeReport())
    }

    func testNothingMergedMeansAnEmptyReport() async throws {
        let (phone, laptop, _) = try await makePhoneAndLaptop()
        _ = try laptop.database.createPlaylist(name: "Laptop Only")
        _ = try await laptop.connect()
        assertUpToDate(await laptop.settle())
        _ = try phone.database.createPlaylist(name: "Phone Only")
        _ = try await phone.connect(code: "PHONE")
        assertUpToDate(await phone.settle())

        let report = await phone.engine.firstConnectMerge()

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.playlistNames, [])
    }

    func testAFirstDeviceOnAnEmptyServerMergesNothing() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        _ = try device.database.createPlaylist(name: "Mix")
        try device.addTrack("One")
        try device.database.setLoved(fileURL: "Artist/Album/One.flac", loved: true, pendingOp: nil)
        _ = try await device.connect()
        assertUpToDate(await device.settle())

        let report = await device.engine.firstConnectMerge()

        XCTAssertTrue(report.isEmpty)
    }

    func testDisconnectingForgetsTheReport() async throws {
        let (phone, laptop, _) = try await makePhoneAndLaptop()
        try laptop.database.setLoved(fileURL: "Artist/Album/One.flac", loved: true, pendingOp: nil)
        _ = try await laptop.connect()
        assertUpToDate(await laptop.settle())
        _ = try await phone.connect(code: "PHONE")
        assertUpToDate(await phone.settle())
        try await phone.engine.disconnect()

        let report = await phone.engine.firstConnectMerge()

        XCTAssertTrue(report.isEmpty)
    }

    func testTheConnectedServerIsReadableWithoutWaitingAndMatchesTheTokenAccount() async throws {
        let server = FakeFlaccyServer()
        let device = try makeDevice(server)
        XCTAssertNil(device.engine.connectedServer)
        let connection = try await device.connect()

        let connected = try XCTUnwrap(device.engine.connectedServer)
        XCTAssertEqual(connected.url, SyncDevice.link.baseURL)
        XCTAssertEqual(connected.name, "Fake")
        XCTAssertEqual(connected.deviceID, connection.deviceID)
        XCTAssertNotNil(device.tokens.token(serverID: ServerSyncEngine.serverID(for: connected.url)))
        XCTAssertEqual(ServerSyncEngine.serverID(for: connected.url), "fake:4545")

        try await device.engine.disconnect()
        XCTAssertNil(device.engine.connectedServer)
        XCTAssertNil(device.tokens.token(serverID: ServerSyncEngine.serverID(for: connected.url)))
    }

    func testTheTokenAccountIsTheLowerCasedHostAndThePort() throws {
        XCTAssertEqual(ServerSyncEngine.serverID(for: try XCTUnwrap(URL(string: "http://Arch:4545"))), "arch:4545")
        XCTAssertEqual(ServerSyncEngine.serverID(for: try XCTUnwrap(URL(string: "http://100.91.211.44:5000"))), "100.91.211.44:5000")
        XCTAssertEqual(ServerSyncEngine.serverID(for: try XCTUnwrap(URL(string: "http://arch"))), "arch:0")
    }
}
