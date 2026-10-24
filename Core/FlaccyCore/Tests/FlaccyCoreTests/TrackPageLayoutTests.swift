import XCTest
@testable import FlaccyCore

final class TrackPageLayoutTests: XCTestCase {

    func testLayoutIdsRoundTrip() {
        for layout in TrackPageLayout.Layout.allCases {
            XCTAssertEqual(TrackPageLayout.Layout(id: layout.id), layout)
        }
        XCTAssertEqual(TrackPageLayout.Layout(id: "nonsense"), .list)
        XCTAssertEqual(TrackPageLayout.Layout(id: ""), .list)
    }

    func testAPlaylistNeverResolvesToColumns() {
        XCTAssertEqual(TrackPageLayout.Layout.columns.resolved(for: .playlist), .list)
        XCTAssertEqual(TrackPageLayout.Layout.columns.resolved(for: .album), .columns)
        XCTAssertEqual(TrackPageLayout.Layout.table.resolved(for: .playlist), .table)
    }

    func testPageWidthPicksTheArrangement() {
        XCTAssertEqual(TrackPageLayout.mode(forWidth: 320), .compact)
        XCTAssertEqual(TrackPageLayout.mode(forWidth: TrackPageLayout.compactMax), .compact)
        XCTAssertEqual(TrackPageLayout.mode(forWidth: TrackPageLayout.compactMax + 1), .regular)
        XCTAssertEqual(TrackPageLayout.mode(forWidth: TrackPageLayout.wideMin - 1), .regular)
        XCTAssertEqual(TrackPageLayout.mode(forWidth: TrackPageLayout.wideMin), .wide)
        XCTAssertEqual(TrackPageLayout.mode(forWidth: 2400), .wide)
    }

    func testColumnCountFollowsTheRoomAndTheBlocks() {
        XCTAssertEqual(TrackPageLayout.columnCount(width: 600, blocks: 4), 1)
        XCTAssertEqual(TrackPageLayout.columnCount(width: 879, blocks: 4), 1)
        XCTAssertEqual(TrackPageLayout.columnCount(width: 880, blocks: 4), 2)
        XCTAssertEqual(TrackPageLayout.columnCount(width: 1360, blocks: 4), 3)
        XCTAssertEqual(TrackPageLayout.columnCount(width: 1360, blocks: 2), 2)
        XCTAssertEqual(TrackPageLayout.columnCount(width: 1360, blocks: 1), 1)
        XCTAssertEqual(TrackPageLayout.columnCount(width: 1360, blocks: 0), 1)
    }

    func testTwoDiscsTakeAColumnEach() {
        XCTAssertEqual(TrackPageLayout.balanceColumns(sizes: [12, 12], columns: 2), [0..<1, 1..<2])
    }

    func testUnevenDiscsKeepTheirOrderAndStayWhole() {
        XCTAssertEqual(TrackPageLayout.balanceColumns(sizes: [10, 6, 8], columns: 2), [0..<1, 1..<3])
        XCTAssertEqual(TrackPageLayout.balanceColumns(sizes: [4, 4, 4, 4], columns: 2), [0..<2, 2..<4])
    }

    func testMoreColumnsThanBlocksLeavesNoneEmpty() {
        let ranges = TrackPageLayout.balanceColumns(sizes: [5, 5], columns: 3)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertTrue(ranges.allSatisfy { !$0.isEmpty })
    }

    func testBalancingCoversEveryBlockExactlyOnce() {
        for sizes in [[9, 1, 1, 1, 9], [1, 1, 1, 1, 1, 1, 1], [30]] {
            for columns in 1...3 {
                let ranges = TrackPageLayout.balanceColumns(sizes: sizes, columns: columns)
                XCTAssertEqual(ranges.first?.lowerBound, 0)
                XCTAssertEqual(ranges.last?.upperBound, sizes.count)
                for pair in zip(ranges, ranges.dropFirst()) {
                    XCTAssertEqual(pair.0.upperBound, pair.1.lowerBound)
                }
            }
        }
    }

    func testAnAlbumWithoutDiscsIsCutIntoEvenRuns() {
        XCTAssertEqual(TrackPageLayout.evenRuns(count: 10, columns: 2), [0..<5, 5..<10])
        XCTAssertEqual(TrackPageLayout.evenRuns(count: 11, columns: 2), [0..<6, 6..<11])
        XCTAssertEqual(TrackPageLayout.evenRuns(count: 7, columns: 3), [0..<3, 3..<6, 6..<7])
        XCTAssertEqual(TrackPageLayout.evenRuns(count: 2, columns: 3), [0..<1, 1..<2])
        XCTAssertEqual(TrackPageLayout.evenRuns(count: 0, columns: 2), [])
    }
}
