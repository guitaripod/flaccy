import FlaccyEngine
import XCTest
@testable import flaccy

nonisolated final class ServerSyncEntitlementTests: XCTestCase {

    func testTheAnswerStartsTrueAndReportsOnlyRealChanges() {
        let entitlement = ServerSyncEntitlement()
        XCTAssertTrue(entitlement.isEntitled)
        XCTAssertFalse(entitlement.set(true))
        XCTAssertTrue(entitlement.set(false))
        XCTAssertFalse(entitlement.isEntitled)
        XCTAssertFalse(entitlement.set(false))
        XCTAssertTrue(entitlement.set(true))
    }

    @MainActor func testAStateThatMayPlayMaySync() {
        let manager = PurchaseManager(store: nil)
        XCTAssertTrue(manager.includesServerSync)
        XCTAssertEqual(manager.includesServerSync, manager.allowsPlayback)
    }

    func testTheMusicLibrarySignInReadsTheAccountTheEngineFilesTheTokenUnder() throws {
        RemoteCredentialStore.shared.useMemoryBackend()
        let url = try XCTUnwrap(URL(string: "http://Pin-Test.example:4545"))
        let account = ServerSyncEngine.serverID(for: url)
        defer { RemoteCredentialStore.shared.removeToken(serverID: account) }
        XCTAssertNil(ServerSyncService.deviceToken(for: url))

        try RemoteCredentialStore.shared.setToken("pinned", serverID: account)

        XCTAssertEqual(ServerSyncService.deviceToken(for: url), "pinned")
        XCTAssertEqual(account, "pin-test.example:4545")
    }

    func testDeviceLastSeenReadsAsAPersonWouldSayIt() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let millisecondsAgo: (Double) -> Int64 = { Int64((now.timeIntervalSince1970 - $0) * 1000) }
        XCTAssertEqual(FlaccyServerDetailViewModel.lastSeen(nil, now: now), "Never seen")
        XCTAssertEqual(FlaccyServerDetailViewModel.lastSeen(millisecondsAgo(10), now: now), "Active now")
        XCTAssertTrue(FlaccyServerDetailViewModel.lastSeen(millisecondsAgo(7_200), now: now).hasPrefix("Last seen "))
    }

    func testTheNudgeShowsOnlyWithNoServerAndUntilItIsClosed() {
        UserDefaults.standard.removeObject(forKey: "flaccy.server.nudgeDismissed")
        XCTAssertTrue(FlaccyServerNudge.isVisible(serverCount: 0))
        XCTAssertFalse(FlaccyServerNudge.isVisible(serverCount: 1))
        FlaccyServerNudge.dismiss()
        XCTAssertFalse(FlaccyServerNudge.isVisible(serverCount: 0))
        UserDefaults.standard.removeObject(forKey: "flaccy.server.nudgeDismissed")
    }
}
