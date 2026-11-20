import XCTest
@testable import FlaccyCore

final class TrackOrderingTests: XCTestCase {

    private struct Row {
        let path: String
        let number: Int
        let title: String
    }

    private func ordered(_ rows: [Row]) -> [Row] {
        TrackOrdering.ordered(rows, number: { $0.number }, path: { $0.path }, title: { $0.title })
    }

    private func sections(_ rows: [Row]) -> [DiscSection<Row>]? {
        TrackOrdering.sections(rows, path: { $0.path })
    }

    func testMultiDiscOrdersByPathNotAlphabeticalTitle() {
        let rows = [
            Row(path: "c1-big_interlude.flac", number: 1, title: "B.I.G. Interlude"),
            Row(path: "a1-intro.flac", number: 1, title: "Life After Death Intro"),
            Row(path: "b1-fuckin_you.flac", number: 1, title: "Fuckin' You Tonight"),
            Row(path: "a2-somebody.flac", number: 2, title: "Somebody's Gotta Die"),
        ]
        XCTAssertEqual(
            ordered(rows).map(\.path),
            ["a1-intro.flac", "a2-somebody.flac", "b1-fuckin_you.flac", "c1-big_interlude.flac"]
        )
    }

    func testSingleDiscOrdersByTrackNumber() {
        let rows = [
            Row(path: "10-last.flac", number: 10, title: "Last"),
            Row(path: "02-second.flac", number: 2, title: "Second"),
            Row(path: "01-first.flac", number: 1, title: "First"),
        ]
        XCTAssertEqual(ordered(rows).map(\.number), [1, 2, 10])
    }

    func testNaturalCompareOrdersNumericRunsByValue() {
        XCTAssertEqual(TrackOrdering.naturalCompare("track2", "track10"), .orderedAscending)
        XCTAssertEqual(TrackOrdering.naturalCompare("cd1/09", "cd1/10"), .orderedAscending)
    }

    func testVinylSidesBecomeSections() {
        let rows = [
            Row(path: "a1-intro.flac", number: 1, title: "Intro"),
            Row(path: "a2-somebody.flac", number: 2, title: "Somebody"),
            Row(path: "b1-fuckin.flac", number: 1, title: "Fuckin"),
            Row(path: "c1-interlude.flac", number: 1, title: "Interlude"),
        ]
        let result = try? XCTUnwrap(sections(rows))
        XCTAssertEqual(result?.map(\.label), ["Side A", "Side B", "Side C"])
        XCTAssertEqual(result?.first?.items.count, 2)
    }

    func testCDDiscTrackPrefixBecomesSections() {
        let rows = [
            Row(path: "Disc/1-01-a.flac", number: 1, title: "A"),
            Row(path: "Disc/1-02-b.flac", number: 2, title: "B"),
            Row(path: "Disc/2-01-c.flac", number: 1, title: "C"),
        ]
        XCTAssertEqual(sections(rows)?.map(\.label), ["Disc 1", "Disc 2"])
    }

    func testCDDiscFoldersBecomeSections() {
        let rows = [
            Row(path: "CD1/01-a.flac", number: 1, title: "A"),
            Row(path: "CD2/01-b.flac", number: 1, title: "B"),
        ]
        XCTAssertEqual(sections(rows)?.map(\.label), ["Disc 1", "Disc 2"])
    }

    func testSingleDiscAlbumHasNoSections() {
        let rows = [
            Row(path: "01-first.flac", number: 1, title: "First"),
            Row(path: "02-second.flac", number: 2, title: "Second"),
            Row(path: "03-third.flac", number: 3, title: "Third"),
        ]
        XCTAssertNil(sections(rows))
    }

    func testTitlePrefixDashDoesNotMatchDisc() {
        XCTAssertNil(TrackOrdering.discLabel("03-title.flac"))
    }

    func testOrderingWithKeysFoldedOnceMatchesComparingStringsEachTime() {
        var generator = SeededGenerator(seed: 20_261_120)
        let pieces = ["a", "B", "cd", "Disc 1/", "CD2/", "0", "01", "1", "10", "2", "-", "_", " ", "é", "É", "ß", "track", "Side"]
        for round in 0..<400 {
            let count = 1 + round % 23
            let rows = (0..<count).map { _ in
                Row(
                    path: (0..<Int.random(in: 1...6, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined(),
                    number: Int.random(in: 0...(round.isMultiple(of: 2) ? 4 : 40), using: &generator),
                    title: (0..<Int.random(in: 0...4, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined()
                )
            }
            XCTAssertEqual(ordered(rows).map(\.path), referenceOrdered(rows).map(\.path), "round \(round)")
            XCTAssertEqual(ordered(rows).map(\.title), referenceOrdered(rows).map(\.title), "round \(round)")
        }
    }

    /// The ordering as it was written before its keys were folded once per
    /// item: every comparison lowercases and compares the strings again.
    private func referenceOrdered(_ rows: [Row]) -> [Row] {
        let less: (Row, Row) -> Bool
        if TrackOrdering.isMultiDisc(rows, number: { $0.number }) {
            less = { TrackOrdering.naturalCompare($0.path.lowercased(), $1.path.lowercased()) == .orderedAscending }
        } else {
            less = { lhs, rhs in
                if lhs.number != rhs.number { return lhs.number < rhs.number }
                return TrackOrdering.lexicographicScalarCompare(lhs.title.lowercased(), rhs.title.lowercased()) == .orderedAscending
            }
        }
        return rows.enumerated()
            .sorted { lhs, rhs in
                if less(lhs.element, rhs.element) { return true }
                if less(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

private struct SeededGenerator: RandomNumberGenerator {

    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
        return mixed ^ (mixed >> 31)
    }
}
