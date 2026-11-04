import XCTest
@testable import flaccy

/// The thresholds every adaptive screen shares, checked against the real
/// iPhone Duo sizes (outer 466 x 678, inner 669 x 951, bar 84 pt, fold 40 pt
/// wide at the centre), against a Pro Max held sideways, which is wide but
/// must not be treated as a two-pane window, and against the iPads (mini
/// 744 x 1133, Air 11 820 x 1180, Pro 13 1032 x 1376) both ways up.
nonisolated final class AdaptiveLayoutTests: XCTestCase {

    @MainActor func testInnerLandscapeSplits() {
        XCTAssertTrue(AdaptiveLayout.usesSplit(size: CGSize(width: 951, height: 669)))
    }

    @MainActor func testOtherSizesDoNotSplit() {
        XCTAssertFalse(AdaptiveLayout.usesSplit(size: CGSize(width: 669, height: 951)))
        XCTAssertFalse(AdaptiveLayout.usesSplit(size: CGSize(width: 678, height: 466)))
        XCTAssertFalse(AdaptiveLayout.usesSplit(size: CGSize(width: 466, height: 678)))
        XCTAssertFalse(AdaptiveLayout.usesSplit(size: CGSize(width: 932, height: 430)))
    }

    @MainActor func testSplitEndsPanesAtTheFold() {
        let fold = CGRect(x: 455.5, y: 0, width: 40, height: 669)
        let geometry = AdaptiveLayout.splitGeometry(width: 951, division: fold)
        XCTAssertEqual(geometry.primaryWidth, 455.5)
        XCTAssertEqual(geometry.secondaryLeading, 495.5)
    }

    @MainActor func testSplitWithoutFoldKeepsAGutterAroundTheCentre() {
        let geometry = AdaptiveLayout.splitGeometry(width: 951, division: nil)
        XCTAssertEqual(geometry.primaryWidth, 455)
        XCTAssertEqual(geometry.secondaryLeading, 495)
    }

    @MainActor func testHorizontalFoldIsNotASplit() {
        let horizontal = CGRect(x: 0, y: 455.5, width: 669, height: 40)
        let geometry = AdaptiveLayout.splitGeometry(width: 951, division: horizontal)
        XCTAssertEqual(geometry.secondaryLeading, 495)
    }

    @MainActor func testIPadColumnNeedsRoomForTheLibraryBesideIt() {
        XCTAssertTrue(AdaptiveLayout.usesSplit(size: CGSize(width: 1376, height: 1032), style: .column))
        XCTAssertTrue(AdaptiveLayout.usesSplit(size: CGSize(width: 1180, height: 820), style: .column))
        XCTAssertTrue(AdaptiveLayout.usesSplit(size: CGSize(width: 1133, height: 744), style: .column))
        XCTAssertFalse(AdaptiveLayout.usesSplit(size: CGSize(width: 1032, height: 1376), style: .column))
        XCTAssertFalse(AdaptiveLayout.usesSplit(size: CGSize(width: 744, height: 1133), style: .column))
        XCTAssertFalse(AdaptiveLayout.usesSplit(size: CGSize(width: 951, height: 669), style: .column))
        XCTAssertFalse(AdaptiveLayout.usesSplit(size: CGSize(width: 1376, height: 500), style: .column))
    }

    @MainActor func testIPadColumnIsAShareOfTheWindowWithinItsBounds() {
        XCTAssertEqual(AdaptiveLayout.playerColumnWidth(forWidth: 1133), 360)
        XCTAssertEqual(AdaptiveLayout.playerColumnWidth(forWidth: 1376), 412)
        XCTAssertEqual(AdaptiveLayout.playerColumnWidth(forWidth: 2400), 440)
        let geometry = AdaptiveLayout.splitGeometry(width: 1376, division: nil, style: .column)
        XCTAssertEqual(geometry.primaryWidth, 964)
        XCTAssertEqual(geometry.secondaryLeading, 964)
    }

    @MainActor func testAFoldDecidesWhereEitherStyleSplits() {
        let fold = CGRect(x: 455.5, y: 0, width: 40, height: 669)
        XCTAssertEqual(
            AdaptiveLayout.splitGeometry(width: 951, division: fold, style: .column),
            AdaptiveLayout.splitGeometry(width: 951, division: fold, style: .halves)
        )
    }

    @MainActor func testSplitStyleFollowsTheIdiom() {
        XCTAssertEqual(AdaptiveLayout.SplitStyle(idiom: .pad), .column)
        XCTAssertEqual(AdaptiveLayout.SplitStyle(idiom: .phone), .halves)
    }

    @MainActor func testAWholeIPadWindowPutsTheCoverBesideTheControls() {
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 1376, height: 1032), horizontalFold: nil), .landscape)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 1180, height: 820), horizontalFold: nil), .landscape)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 1032, height: 1376), horizontalFold: nil), .portrait)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 951, height: 669), horizontalFold: nil), .portrait)
    }

    @MainActor func testHomeGoesWideOnlyWithRoomForTheHeroBesideTwoColumnsOfTiles() {
        XCTAssertFalse(AdaptiveLayout.homeIsWide(contentWidth: 393))
        XCTAssertFalse(AdaptiveLayout.homeIsWide(contentWidth: 667))
        XCTAssertTrue(AdaptiveLayout.homeIsWide(contentWidth: 760))
        XCTAssertTrue(AdaptiveLayout.homeIsWide(contentWidth: 1032))
    }

    @MainActor func testPhoneWidthsKeepThreeColumns() {
        XCTAssertEqual(AdaptiveLayout.gridColumns(forWidth: 382), 3)
        XCTAssertEqual(AdaptiveLayout.gridColumns(forWidth: 393), 3)
        XCTAssertEqual(AdaptiveLayout.gridColumns(forWidth: 455), 3)
    }

    @MainActor func testWideGridsAreAlwaysEven() {
        for width in stride(from: CGFloat(500), through: 1400, by: 7) {
            XCTAssertEqual(AdaptiveLayout.gridColumns(forWidth: width) % 2, 0, "width \(width)")
        }
        XCTAssertEqual(AdaptiveLayout.gridColumns(forWidth: 669), 4)
        XCTAssertEqual(AdaptiveLayout.gridColumns(forWidth: 951), 6)
    }

    @MainActor func testArtistShelvesAreEvenAndStartAtTwo() {
        XCTAssertEqual(AdaptiveLayout.shelfColumns(forWidth: 300), 2)
        XCTAssertEqual(AdaptiveLayout.shelfColumns(forWidth: 382), 2)
        XCTAssertEqual(AdaptiveLayout.shelfColumns(forWidth: 594), 4)
        for width in stride(from: CGFloat(200), through: 1400, by: 11) {
            XCTAssertEqual(AdaptiveLayout.shelfColumns(forWidth: width) % 2, 0, "width \(width)")
        }
    }

    @MainActor func testDetailHeaderStyles() {
        XCTAssertEqual(AdaptiveLayout.detailHeaderStyle(forSize: CGSize(width: 402, height: 780)), .stacked)
        XCTAssertEqual(AdaptiveLayout.detailHeaderStyle(forSize: CGSize(width: 382, height: 644)), .banner)
        XCTAssertEqual(AdaptiveLayout.detailHeaderStyle(forSize: CGSize(width: 371, height: 669)), .banner)
        XCTAssertEqual(AdaptiveLayout.detailHeaderStyle(forSize: CGSize(width: 669, height: 951)), .banner)
        XCTAssertEqual(AdaptiveLayout.detailHeaderStyle(forSize: CGSize(width: 594, height: 466)), .sideBySide)
        XCTAssertEqual(AdaptiveLayout.detailHeaderStyle(forSize: CGSize(width: 867, height: 669)), .sideBySide)
    }

    @MainActor func testPlayerLayouts() {
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 466, height: 678), horizontalFold: nil), .portrait)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 455, height: 669), horizontalFold: nil), .portrait)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 678, height: 466), horizontalFold: nil), .landscape)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 932, height: 430), horizontalFold: nil), .landscape)
    }

    @MainActor func testFocusNeedsRoomToSplit() {
        let geometry = AdaptiveLayout.SplitGeometry(primaryWidth: 455.5, secondaryLeading: 495.5)
        XCTAssertEqual(
            AdaptiveLayout.playerLayout(size: CGSize(width: 951, height: 669), horizontalFold: nil, focus: geometry),
            .focus(geometry)
        )
        XCTAssertEqual(
            AdaptiveLayout.playerLayout(size: CGSize(width: 455, height: 669), horizontalFold: nil, focus: geometry),
            .portrait
        )
    }

    @MainActor func testLaptopNeedsAFoldAcrossATallView() {
        let fold: ClosedRange<CGFloat> = 455.5...495.5
        XCTAssertEqual(
            AdaptiveLayout.playerLayout(size: CGSize(width: 669, height: 951), horizontalFold: fold),
            .laptop(foldTop: 455.5, foldBottom: 495.5)
        )
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 669, height: 951), horizontalFold: nil), .portrait)
    }
}
