import XCTest
@testable import FlaccyCore

final class LibraryFilterRulesTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ago(_ days: Int) -> Date {
        now.addingTimeInterval(-Double(days) * 86_400)
    }

    private func added(_ prefix: String, _ days: ClosedRange<Int>) -> [(id: String, dateAdded: Date)] {
        days.map { (id: "\(prefix)\($0)", dateAdded: ago($0)) }
    }

    private func ids(_ prefix: String, _ numbers: ClosedRange<Int>) -> [String] {
        numbers.map { "\(prefix)\($0)" }
    }

    func testR1RecentlyAddedSortsNewestFirstWhateverTheInputOrder() {
        let entries = Array(added("s", 1...12).reversed())
        XCTAssertEqual(
            LibraryFilterRules.recentlyAdded(entries, now: now, thresholds: .songs),
            ids("s", 1...12)
        )
    }

    func testR2ThinRecentWindowFallsBackToEverythingUnderTheCap() {
        let entries = added("s", 1...9) + [
            (id: "s10", dateAdded: ago(40)), (id: "s11", dateAdded: ago(50)), (id: "s12", dateAdded: ago(60)),
        ]
        XCTAssertEqual(
            LibraryFilterRules.recentlyAdded(entries, now: now, thresholds: .songs),
            ids("s", 1...12)
        )
    }

    func testR3RecentWindowIncludesTheThirtiethDayAndNothingOlder() {
        XCTAssertEqual(
            LibraryFilterRules.recentlyAdded(added("s", 1...45), now: now, thresholds: .songs),
            ids("s", 1...30)
        )
    }

    func testR4NothingRecentFallsBackToTheNewestForty() {
        let entries = (1...45).map { (id: "s\($0)", dateAdded: ago(99 + $0)) }
        XCTAssertEqual(
            LibraryFilterRules.recentlyAdded(entries, now: now, thresholds: .songs),
            ids("s", 1...40)
        )
    }

    func testR5RecentlyPlayedDropsNeverPlayed() {
        let entries: [(id: String, lastPlayed: Date?)] = [
            ("p1", ago(1)), ("p2", ago(2)), ("p3", ago(3)), ("q1", nil), ("q2", nil),
        ]
        XCTAssertEqual(
            LibraryFilterRules.recentlyPlayed(entries, now: now, thresholds: .songs),
            ["p1", "p2", "p3"]
        )
    }

    func testR6RecentlyPlayedKeepsOnlyTheWindowOnceItIsFullEnough() {
        var entries: [(id: String, lastPlayed: Date?)] = (1...10).map { ("p\($0)", ago($0)) }
        entries.append(("o1", ago(50)))
        entries.append(("o2", ago(60)))
        XCTAssertEqual(
            LibraryFilterRules.recentlyPlayed(entries, now: now, thresholds: .songs),
            ids("p", 1...10)
        )
    }

    func testR7AlbumsUseTheirOwnMinimum() {
        let entries = added("a", 1...6) + (1...5).map { (id: "b\($0)", dateAdded: ago(99 + $0)) }
        XCTAssertEqual(
            LibraryFilterRules.recentlyAdded(entries, now: now, thresholds: .albums),
            ids("a", 1...6)
        )
    }

    func testR8AlbumsFallBackToTheNewestTwentyFour() {
        let entries = added("a", 1...5) + (1...30).map { (id: "b\($0)", dateAdded: ago(99 + $0)) }
        XCTAssertEqual(
            LibraryFilterRules.recentlyAdded(entries, now: now, thresholds: .albums),
            ids("a", 1...5) + ids("b", 1...19)
        )
    }

    func testR9RediscoverNeedsPlaysAndSilenceAndRanksByNeglect() {
        let entries: [(id: String, plays: Int, lastPlayed: Date?)] = [
            ("A", 10, ago(20)), ("B", 5, ago(14)), ("C", 1, ago(40)),
            ("D", 9, ago(13)), ("E", 30, ago(100)), ("F", 3, nil),
        ]
        XCTAssertEqual(LibraryFilterRules.rediscover(entries, now: now), ["A", "B", "E"])
    }

    func testRediscoverBreaksScoreTiesByIdAndCountsWholeDays() {
        let almostFourteen = now.addingTimeInterval(-14 * 86_400 + 1)
        let entries: [(id: String, plays: Int, lastPlayed: Date?)] = [
            ("z", 4, ago(20)), ("m", 4, ago(20)), ("early", 9, almostFourteen),
        ]
        XCTAssertEqual(LibraryFilterRules.rediscover(entries, now: now), ["m", "z"])
    }

    func testR10MostPlayedOrdersByPlaysThenRecencyThenTitle() {
        let entries: [(id: String, plays: Int, lastPlayed: Date?, title: String)] = [
            ("x", 3, ago(5), "b"), ("y", 3, ago(2), "a"), ("z", 5, ago(9), "c"),
            ("w", 0, ago(1), "d"), ("v", 3, nil, "e"),
        ]
        XCTAssertEqual(LibraryFilterRules.mostPlayed(entries), ["z", "y", "x", "v"])
    }

    func testMostPlayedTitleTiebreakIgnoresCaseThenFallsBackToRaw() {
        let entries: [(id: String, plays: Int, lastPlayed: Date?, title: String)] = [
            ("c", 2, nil, "beta"), ("b", 2, nil, "Alpha"), ("a", 2, nil, "alpha"),
        ]
        XCTAssertEqual(LibraryFilterRules.mostPlayed(entries), ["b", "a", "c"])
    }
}
