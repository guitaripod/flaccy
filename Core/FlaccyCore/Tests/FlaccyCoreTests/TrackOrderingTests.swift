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
}
