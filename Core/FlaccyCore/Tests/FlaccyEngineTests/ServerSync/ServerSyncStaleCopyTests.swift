import FlaccyCore
import Foundation
import XCTest

@testable import FlaccyEngine

final class ServerSyncStaleCopyTests: XCTestCase {

    private let base: TimeInterval = 1_700_000_000

    private func heldPlays(_ server: FakeFlaccyServer) -> [String] {
        server.snapshot().plays.values.map(\.item).sorted { $0.ts < $1.ts }.map { "\($0.ts - Int64(base)):\($0.ref.title)" }
    }

    func testPlaysMadeOnAStaleCopyKeepTheirOwnIdsWhenTheCopyMovesToANewInstance() async throws {
        let server = FakeFlaccyServer()
        let original = try makeDevice(server)
        let titles = ["One", "Two", "Three", "Four", "Five", "Six"]
        for title in titles { try original.addTrack(title) }
        _ = try await original.connect()
        try original.play("One", at: base + 100)
        try original.play("Two", at: base + 200)
        assertUpToDate(await original.settle())
        let copy = try SyncDevice(server: server, copying: original)
        try copy.adoptToken(of: original, serverID: "fake:4545")
        try original.play("Three", at: base + 300)
        try original.play("Four", at: base + 400)
        assertUpToDate(await original.settle())

        try copy.play("Five", at: base + 500)
        try copy.play("Six", at: base + 600)
        assertUpToDate(await copy.settle())
        assertUpToDate(await original.settle())
        assertUpToDate(await copy.settle())

        XCTAssertEqual(heldPlays(server), ["100:One", "200:Two", "300:Three", "400:Four", "500:Five", "600:Six"])
        XCTAssertEqual(try original.scrobbleCount(), 6)
        XCTAssertEqual(try copy.scrobbleCount(), 6)
    }
}
