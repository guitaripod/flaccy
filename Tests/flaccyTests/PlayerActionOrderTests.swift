import XCTest
@testable import flaccy

nonisolated final class PlayerActionOrderTests: XCTestCase {

    private static let suite = "com.midgarcorp.flaccy.tests.actionrow"

    @MainActor private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: Self.suite)!
        defaults.removePersistentDomain(forName: Self.suite)
        return defaults
    }

    func testAFreshOrderIsTheRowAsShipped() {
        XCTAssertEqual(PlayerActionOrder.decode(nil).actions, PlayerAction.allCases)
        XCTAssertEqual(PlayerActionOrder.decode("").actions, PlayerAction.allCases)
        XCTAssertEqual(PlayerActionOrder.decode(" , ").actions, PlayerAction.allCases)
    }

    func testASavedOrderKeepsUnknownActionsOutAndAddsMissingOnesLast() {
        let order = PlayerActionOrder.decode("queue,bogus,queue,lyrics")
        XCTAssertEqual(order.actions, [.queue, .lyrics, .shuffle, .repeatMode, .airplay, .sleepTimer, .share])
    }

    func testMovingClampsBothEnds() {
        let order = PlayerActionOrder(actions: [.queue, .shuffle, .lyrics])
        XCTAssertEqual(order.moving(from: 0, to: -4).actions.first, .queue)
        XCTAssertEqual(order.moving(from: 0, to: 99).actions.last, .queue)
        XCTAssertEqual(order.moving(from: 9, to: 0), order)
    }

    func testAnOrderRoundTripsThroughItsText() {
        let order = PlayerActionOrder
            .standard
            .moving(from: 6, to: 0)
            .moving(from: 2, to: 5)
        XCTAssertEqual(PlayerActionOrder.decode(order.encoded), order)
    }

    @MainActor func testTheStoreRemembersAndRestoresTheOrder() {
        let defaults = makeDefaults()
        let store = PlayerActionOrderStore(defaults: defaults)
        XCTAssertEqual(store.order, .standard)

        let custom = PlayerActionOrder.standard.moving(from: 5, to: 0)
        store.order = custom
        XCTAssertEqual(PlayerActionOrderStore(defaults: defaults).order, custom)

        store.restoreDefault()
        XCTAssertEqual(store.order, .standard)
    }
}
