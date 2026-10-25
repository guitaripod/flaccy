import Foundation
import XCTest
@testable import FlaccyCore

/// Mirrored by the tests in `linux/shared/src/remote/cache_policy.rs`, with times in milliseconds there.
final class RemoteCachePolicyTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ key: String, _ bytes: Int64, minutesAgo: Double, pinned: Bool = false) -> RemoteCachePolicy.Entry {
        RemoteCachePolicy.Entry(
            key: key, bytes: bytes, lastUsed: base.addingTimeInterval(-minutesAgo * 60), pinned: pinned
        )
    }

    func testDefaultCapIsTwoGiB() {
        XCTAssertEqual(RemoteCachePolicy.defaultCapBytes, 2_147_483_648)
    }

    func testUnderTheCapEvictsNothing() {
        let entries = [entry("a", 40, minutesAgo: 5), entry("b", 60, minutesAgo: 9)]

        XCTAssertEqual(RemoteCachePolicy.victims(entries: entries, capBytes: 100, protected: []), [])
    }

    func testOverTheCapByOneEntryEvictsTheOldest() {
        let entries = [entry("new", 50, minutesAgo: 1), entry("old", 50, minutesAgo: 30), entry("mid", 1, minutesAgo: 10)]

        XCTAssertEqual(RemoteCachePolicy.victims(entries: entries, capBytes: 100, protected: []), ["old"])
    }

    func testEvictionStopsOnceTheTotalFits() {
        let entries = [entry("a", 40, minutesAgo: 30), entry("b", 40, minutesAgo: 20), entry("c", 40, minutesAgo: 10)]

        XCTAssertEqual(RemoteCachePolicy.victims(entries: entries, capBytes: 100, protected: []), ["a"])
    }

    func testPinnedHugeEntryDoesNotTriggerEviction() {
        let entries = [entry("pinned", 10_000, minutesAgo: 90, pinned: true), entry("a", 60, minutesAgo: 5)]

        XCTAssertEqual(RemoteCachePolicy.victims(entries: entries, capBytes: 100, protected: []), [])
    }

    func testPinnedEntryIsNeverEvictedEvenWhenOverTheCap() {
        let entries = [entry("pinned", 80, minutesAgo: 90, pinned: true), entry("a", 60, minutesAgo: 5), entry("b", 60, minutesAgo: 6)]

        XCTAssertEqual(RemoteCachePolicy.victims(entries: entries, capBytes: 100, protected: []), ["b"])
    }

    func testProtectedOldestIsSkippedAndTheNextOldestGoes() {
        let entries = [entry("playing", 60, minutesAgo: 30), entry("b", 60, minutesAgo: 20), entry("c", 60, minutesAgo: 10)]

        XCTAssertEqual(RemoteCachePolicy.victims(entries: entries, capBytes: 120, protected: ["playing"]), ["b"])
    }

    func testTiedLastUseIsBrokenByKeyAscending() {
        let entries = [entry("zeta", 60, minutesAgo: 10), entry("alpha", 60, minutesAgo: 10)]

        XCTAssertEqual(RemoteCachePolicy.victims(entries: entries, capBytes: 100, protected: []), ["alpha"])
    }
}
