import XCTest
@testable import flaccy

/// The thresholds every adaptive screen shares, checked against the real
/// iPhone Duo sizes (outer 466 x 678, inner 669 x 951, bar 84 pt, fold 40 pt
/// wide at the centre) and against a Pro Max held sideways, which is wide but
/// must not be treated as a two-pane window.
final class AdaptiveLayoutTests: XCTestCase {

    func testInnerLandscapeSplits() {
        XCTAssertTrue(AdaptiveLayout.usesSplit(size: CGSize(width: 951, height: 669)))
    }

    func testOtherSizesDoNotSplit() {
        XCTAssertFalse(AdaptiveLayout.usesSplit(size: CGSize(width: 669, height: 951)))
        XCTAssertFalse(AdaptiveLayout.usesSplit(size: CGSize(width: 678, height: 466)))
        XCTAssertFalse(AdaptiveLayout.usesSplit(size: CGSize(width: 466, height: 678)))
        XCTAssertFalse(AdaptiveLayout.usesSplit(size: CGSize(width: 932, height: 430)))
    }

    func testSplitEndsPanesAtTheFold() {
        let fold = CGRect(x: 455.5, y: 0, width: 40, height: 669)
        let geometry = AdaptiveLayout.splitGeometry(width: 951, division: fold)
        XCTAssertEqual(geometry.primaryWidth, 455.5)
        XCTAssertEqual(geometry.secondaryLeading, 495.5)
    }

    func testSplitWithoutFoldKeepsAGutterAroundTheCentre() {
        let geometry = AdaptiveLayout.splitGeometry(width: 951, division: nil)
        XCTAssertEqual(geometry.primaryWidth, 455)
        XCTAssertEqual(geometry.secondaryLeading, 495)
    }

    func testHorizontalFoldIsNotASplit() {
        let horizontal = CGRect(x: 0, y: 455.5, width: 669, height: 40)
        let geometry = AdaptiveLayout.splitGeometry(width: 951, division: horizontal)
        XCTAssertEqual(geometry.secondaryLeading, 495)
    }

    func testPhoneWidthsKeepThreeColumns() {
        XCTAssertEqual(AdaptiveLayout.gridColumns(forWidth: 382), 3)
        XCTAssertEqual(AdaptiveLayout.gridColumns(forWidth: 393), 3)
        XCTAssertEqual(AdaptiveLayout.gridColumns(forWidth: 455), 3)
    }

    func testWideGridsAreAlwaysEven() {
        for width in stride(from: CGFloat(500), through: 1400, by: 7) {
            XCTAssertEqual(AdaptiveLayout.gridColumns(forWidth: width) % 2, 0, "width \(width)")
        }
        XCTAssertEqual(AdaptiveLayout.gridColumns(forWidth: 669), 4)
        XCTAssertEqual(AdaptiveLayout.gridColumns(forWidth: 951), 6)
    }

    func testArtistShelvesAreEvenAndStartAtTwo() {
        XCTAssertEqual(AdaptiveLayout.shelfColumns(forWidth: 300), 2)
        XCTAssertEqual(AdaptiveLayout.shelfColumns(forWidth: 382), 2)
        XCTAssertEqual(AdaptiveLayout.shelfColumns(forWidth: 594), 4)
        for width in stride(from: CGFloat(200), through: 1400, by: 11) {
            XCTAssertEqual(AdaptiveLayout.shelfColumns(forWidth: width) % 2, 0, "width \(width)")
        }
    }

    func testDetailHeaderStyles() {
        XCTAssertEqual(AdaptiveLayout.detailHeaderStyle(forSize: CGSize(width: 402, height: 780)), .stacked)
        XCTAssertEqual(AdaptiveLayout.detailHeaderStyle(forSize: CGSize(width: 382, height: 644)), .banner)
        XCTAssertEqual(AdaptiveLayout.detailHeaderStyle(forSize: CGSize(width: 371, height: 669)), .banner)
        XCTAssertEqual(AdaptiveLayout.detailHeaderStyle(forSize: CGSize(width: 669, height: 951)), .banner)
        XCTAssertEqual(AdaptiveLayout.detailHeaderStyle(forSize: CGSize(width: 594, height: 466)), .sideBySide)
        XCTAssertEqual(AdaptiveLayout.detailHeaderStyle(forSize: CGSize(width: 867, height: 669)), .sideBySide)
    }

    func testPlayerLayouts() {
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 466, height: 678), horizontalFold: nil), .portrait)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 455, height: 669), horizontalFold: nil), .portrait)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 678, height: 466), horizontalFold: nil), .landscape)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 932, height: 430), horizontalFold: nil), .landscape)
    }

    func testFocusNeedsRoomToSplit() {
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

    func testLaptopNeedsAFoldAcrossATallView() {
        let fold: ClosedRange<CGFloat> = 455.5...495.5
        XCTAssertEqual(
            AdaptiveLayout.playerLayout(size: CGSize(width: 669, height: 951), horizontalFold: fold),
            .laptop(foldTop: 455.5, foldBottom: 495.5)
        )
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 669, height: 951), horizontalFold: nil), .portrait)
    }
}
