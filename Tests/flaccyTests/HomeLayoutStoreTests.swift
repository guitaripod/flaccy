import FlaccyCore
import XCTest
@testable import flaccy

nonisolated final class HomeLayoutStoreTests: XCTestCase {

    private static let suite = "com.midgarcorp.flaccy.tests.homelayout"

    @MainActor private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: Self.suite)!
        defaults.removePersistentDomain(forName: Self.suite)
        return defaults
    }

    @MainActor func testAFreshStoreIsTheStandardLayout() {
        let store = HomeLayoutStore(defaults: makeDefaults())
        XCTAssertEqual(store.layout, .standard)
    }

    @MainActor func testALayoutRoundTripsThroughDefaults() {
        let defaults = makeDefaults()
        let store = HomeLayoutStore(defaults: defaults)
        store.layout = HomeLayout.standard
            .moving(from: 5, to: 0)
            .setting(.thisWeek, visible: false)
        let reopened = HomeLayoutStore(defaults: defaults)
        XCTAssertEqual(reopened.layout.order.first, .recentlyAdded)
        XCTAssertFalse(reopened.layout.isVisible(.thisWeek))
        XCTAssertEqual(reopened.layout, store.layout)
    }

    @MainActor func testRestoreDefaultReturnsToStandard() {
        let store = HomeLayoutStore(defaults: makeDefaults())
        store.layout = HomeLayout.standard.setting(.jumpBackIn, visible: false)
        store.restoreDefault()
        XCTAssertTrue(store.layout.isStandard)
    }

    @MainActor func testChangingTheLayoutPostsOnceAndAnUnchangedOneDoesNot() {
        let store = HomeLayoutStore(defaults: makeDefaults())
        var posts = 0
        let observer = NotificationCenter.default.addObserver(
            forName: HomeLayoutStore.didChange, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.layout = HomeLayout.standard.setting(.onThisDay, visible: false)
        store.layout = HomeLayout.standard.setting(.onThisDay, visible: false)
        XCTAssertEqual(posts, 1)
    }
}
