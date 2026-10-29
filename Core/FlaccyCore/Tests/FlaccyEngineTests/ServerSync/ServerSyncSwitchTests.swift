import FlaccyCore
import Foundation
import XCTest

@testable import FlaccyEngine

final class ServerSyncSwitchTests: XCTestCase {

    private static func link(host: String, code: String) throws -> FlaccyServerLink {
        FlaccyServerLink(baseURL: try XCTUnwrap(URL(string: "http://\(host):4545")), enrollmentCode: code, name: host)
    }

    func testAConnectedDeviceThatConnectsToAnotherServerMergesWhatTheNewServerHolds() async throws {
        let own = FakeFlaccyServer()
        let home = FakeFlaccyServer()
        let routes = RoutedTransports(servers: ["own": own, "home": home])
        let mac = try SyncDevice(server: own, transports: routes)
        let laptop = try SyncDevice(server: home, transports: routes)
        for title in ["One", "Two", "Three"] {
            try mac.addTrack(title)
            try laptop.addTrack(title)
        }
        let macRoadTrip = try XCTUnwrap(mac.database.createPlaylist(name: "Road Trip").id)
        try mac.database.addTracksToPlaylist(playlistId: macRoadTrip, trackFileURLs: ["Artist/Album/One.flac"])
        try mac.database.setLoved(fileURL: "Artist/Album/One.flac", loved: true, pendingOp: nil)
        own.newCode("MAC")
        _ = try await mac.engine.connect(link: Self.link(host: "own", code: "MAC"), deviceName: "Mac", startSyncing: false)
        assertUpToDate(await mac.settle())
        _ = await mac.engine.firstConnectMerge()

        let laptopRoadTrip = try XCTUnwrap(laptop.database.createPlaylist(name: "Road Trip").id)
        try laptop.database.addTracksToPlaylist(playlistId: laptopRoadTrip, trackFileURLs: ["Artist/Album/Two.flac"])
        try laptop.database.setLoved(fileURL: "Artist/Album/Three.flac", loved: true, pendingOp: nil)
        home.newCode("LAPTOP")
        _ = try await laptop.engine.connect(link: Self.link(host: "home", code: "LAPTOP"), deviceName: "Laptop", startSyncing: false)
        assertUpToDate(await laptop.settle())

        home.newCode("SWITCH")
        let connection = try await mac.engine.connect(link: Self.link(host: "home", code: "SWITCH"), deviceName: "Mac", startSyncing: false)
        assertUpToDate(await mac.settle())

        XCTAssertEqual(connection.serverName, "home")
        XCTAssertEqual(mac.engine.connectedServer?.url.host, "home")
        let report = await mac.engine.firstConnectMerge()
        XCTAssertEqual(report.playlistNames, ["Road Trip"])
        XCTAssertEqual(report.lovesAdded, 1)
        XCTAssertEqual(try mac.playlistTitles("Road Trip").sorted(), ["One", "Two"])
        XCTAssertEqual(try laptop.playlistTitles("Road Trip").count, 1)
        assertUpToDate(await laptop.settle())
        XCTAssertEqual(try laptop.playlistTitles("Road Trip").sorted(), ["One", "Two"])
        XCTAssertTrue(try laptop.isLoved("Artist/Album/One.flac"))
    }
}
