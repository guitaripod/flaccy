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

    @MainActor func testSplitStyleFollowsTheFold() {
        XCTAssertEqual(AdaptiveLayout.SplitStyle(division: CGRect(x: 455.5, y: 0, width: 40, height: 669)), .halves)
        XCTAssertEqual(AdaptiveLayout.SplitStyle(division: CGRect(x: 0, y: 455.5, width: 669, height: 40)), .column)
        XCTAssertEqual(AdaptiveLayout.SplitStyle(division: nil), .column)
    }

    @MainActor func testThePlayerPaneWaitsForSomethingToPlay() {
        let inner = CGSize(width: 951, height: 669)
        XCTAssertFalse(AdaptiveLayout.showsPlayerPane(size: inner, style: .halves, hasTrack: false, isShown: true))
        XCTAssertTrue(AdaptiveLayout.showsPlayerPane(size: inner, style: .halves, hasTrack: true, isShown: true))
        XCTAssertFalse(AdaptiveLayout.showsPlayerPane(size: CGSize(width: 669, height: 951), style: .halves, hasTrack: true, isShown: true))
        let iPad = CGSize(width: 1376, height: 1032)
        XCTAssertTrue(AdaptiveLayout.showsPlayerPane(size: iPad, style: .column, hasTrack: true, isShown: true))
        XCTAssertFalse(AdaptiveLayout.showsPlayerPane(size: iPad, style: .column, hasTrack: true, isShown: false))
        XCTAssertFalse(AdaptiveLayout.showsPlayerPane(size: iPad, style: .column, hasTrack: false, isShown: true))
    }

    /// The Now Playing half on the inner display: 455 pt wide, an 82 pt top
    /// inset that only the status cluster in its top trailing corner explains.
    @MainActor func testTheCoverRisesBesideACornerCutout() {
        let cluster = CGRect(x: 321.3, y: 0, width: 134, height: 82)
        let clearance = AdaptiveLayout.mediaClearance(column: 28...427.3, safeTop: 82, occlusions: [cluster])
        XCTAssertEqual(clearance.rise, 82)
        XCTAssertEqual(clearance.leading, 0)
        XCTAssertEqual(clearance.trailing, 427.3 - (321.3 - AdaptiveLayout.mediaClearanceGap), accuracy: 0.001)
    }

    @MainActor func testTheCoverStaysBelowAnInsetNothingExplains() {
        XCTAssertEqual(AdaptiveLayout.mediaClearance(column: 28...427.3, safeTop: 82, occlusions: []), .none)
        XCTAssertEqual(AdaptiveLayout.mediaClearance(column: 28...427.3, safeTop: 0, occlusions: [CGRect(x: 321, y: 0, width: 134, height: 82)]), .none)
        XCTAssertEqual(AdaptiveLayout.mediaClearance(column: 28...427.3, safeTop: 62, occlusions: [CGRect(x: 150, y: 11, width: 126, height: 37)]), .none)
        XCTAssertEqual(AdaptiveLayout.mediaClearance(column: 28...427.3, safeTop: 82, occlusions: [CGRect(x: 0, y: 300, width: 40, height: 40)]), .none)
        XCTAssertEqual(AdaptiveLayout.mediaClearance(column: 28...200, safeTop: 82, occlusions: [CGRect(x: 150, y: 0, width: 134, height: 82)]), .none)
    }

    @MainActor func testACutoutOnTheLeadingCornerPushesTheCoverTheOtherWay() {
        let clearance = AdaptiveLayout.mediaClearance(column: 28...427.3, safeTop: 82, occlusions: [CGRect(x: 0, y: 0, width: 134, height: 82)])
        XCTAssertEqual(clearance.leading, 134 + AdaptiveLayout.mediaClearanceGap - 28, accuracy: 0.001)
        XCTAssertEqual(clearance.trailing, 0)
    }

    /// The whole inner display with nothing playing: the library runs from the
    /// leading edge to the 84 pt bar, the fold at 455.5 to 495.5.
    @MainActor func testAFoldGridMeetsTheFoldWithOneTileWidthOnBothSides() {
        let grid = AdaptiveLayout.foldGrid(content: 20...855, fold: 455.5...495.5, columnsForSide: AdaptiveLayout.gridColumns(forWidth:))
        XCTAssertEqual(grid?.columnsPerSide, 3)
        XCTAssertEqual(grid?.sideWidth, 359.5)
        XCTAssertEqual(grid?.gap, 40)
        XCTAssertEqual(grid?.extraLeading, 76)
        XCTAssertEqual(grid?.extraTrailing, 0)
    }

    @MainActor func testNoFoldGridWithoutAFoldInsideTheContent() {
        XCTAssertNil(AdaptiveLayout.foldGrid(content: 20...855, fold: nil, columnsForSide: AdaptiveLayout.gridColumns(forWidth:)))
        XCTAssertNil(AdaptiveLayout.foldGrid(content: 20...440, fold: 455.5...495.5, columnsForSide: AdaptiveLayout.gridColumns(forWidth:)))
        XCTAssertNil(AdaptiveLayout.foldGrid(content: 300...700, fold: 455.5...495.5, columnsForSide: AdaptiveLayout.gridColumns(forWidth:)))
    }

    @MainActor func testFoldHalvesEndAndStartAtTheFold() {
        let halves = AdaptiveLayout.foldHalves(content: 24...843, fold: 455.5...495.5, leadingMinimum: 300, trailingMinimum: 300)
        XCTAssertEqual(halves, AdaptiveLayout.FoldHalves(leading: 431.5, trailing: 347.5, gap: 40))
        XCTAssertNil(AdaptiveLayout.foldHalves(content: 24...843, fold: 455.5...495.5, leadingMinimum: 300, trailingMinimum: 360))
        XCTAssertNil(AdaptiveLayout.foldHalves(content: 24...843, fold: nil, leadingMinimum: 0, trailingMinimum: 0))
    }

    @MainActor func testAWholeIPadWindowPutsTheCoverBesideTheControls() {
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 1376, height: 1032), horizontalFold: nil), .landscape)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 1180, height: 820), horizontalFold: nil), .landscape)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 1032, height: 1376), horizontalFold: nil), .portrait)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 951, height: 669), horizontalFold: nil, hasFold: true), .portrait)
    }

    @MainActor func testAPhoneOnItsSideKeepsThePhonesProportions() {
        XCTAssertEqual(AdaptiveLayout.landscapeSplit(size: CGSize(width: 932, height: 430)), .proportional)
        XCTAssertEqual(AdaptiveLayout.landscapeSplit(size: CGSize(width: 874, height: 402)), .proportional)
        XCTAssertEqual(AdaptiveLayout.landscapeSplit(size: CGSize(width: 667, height: 375)), .proportional)
        XCTAssertEqual(AdaptiveLayout.landscapeSplit(size: CGSize(width: 1000, height: 560)), .proportional)
    }

    @MainActor func testAnIPadOnItsSideGivesTheControlsAColumnTheCoverCanSpare() {
        XCTAssertEqual(AdaptiveLayout.landscapeSplit(size: CGSize(width: 1194, height: 834)), .sideColumn(controlsWidth: 440))
        XCTAssertEqual(AdaptiveLayout.landscapeSplit(size: CGSize(width: 1376, height: 1032)), .sideColumn(controlsWidth: 440))
        XCTAssertEqual(AdaptiveLayout.landscapeSplit(size: CGSize(width: 1158, height: 756)), .sideColumn(controlsWidth: 440))
        XCTAssertEqual(AdaptiveLayout.landscapeSplit(size: CGSize(width: 773, height: 756)), .sideColumn(controlsWidth: 340))
        XCTAssertEqual(AdaptiveLayout.landscapeSplit(size: CGSize(width: 800, height: 834)), .sideColumn(controlsWidth: 340))
        guard case .sideColumn(let narrowing) = AdaptiveLayout.landscapeSplit(size: CGSize(width: 951, height: 669)) else {
            return XCTFail("a 951 x 669 window has room for the side column")
        }
        XCTAssertEqual(narrowing, 951 - 84 - 669 * 0.72, accuracy: 0.5)
    }

    @MainActor func testTheCoverBesideTheControlsIsNeverSmallerThanAboveThem() {
        let sizes = [
            CGSize(width: 800, height: 834), CGSize(width: 773, height: 756), CGSize(width: 834, height: 600),
            CGSize(width: 1158, height: 756), CGSize(width: 1194, height: 834), CGSize(width: 951, height: 669),
            CGSize(width: 720, height: 800), CGSize(width: 760, height: 834), CGSize(width: 900, height: 1000),
        ]
        for size in sizes where size.height > AdaptiveLayout.playerLandscapeMaximumHeight {
            guard AdaptiveLayout.playerLayout(size: size, horizontalFold: nil) == .landscape else { continue }
            XCTAssertGreaterThanOrEqual(
                AdaptiveLayout.sideBySideCover(size: size), AdaptiveLayout.portraitCover(size: size, hasFold: false),
                "\(size)"
            )
        }
        XCTAssertEqual(AdaptiveLayout.sideBySideCover(size: CGSize(width: 800, height: 834)), 376)
        XCTAssertEqual(AdaptiveLayout.portraitCover(size: CGSize(width: 800, height: 834), hasFold: false), 834 * 0.42, accuracy: 0.01)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 756, height: 1158), horizontalFold: nil), .portrait)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 834, height: 1194), horizontalFold: nil), .portrait)
    }

    @MainActor func testASquarishIPadWindowPutsTheCoverBesideTheControls() {
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 800, height: 834), horizontalFold: nil), .landscape)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 834, height: 600), horizontalFold: nil), .landscape)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 951, height: 669), horizontalFold: nil), .landscape)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 773, height: 756), horizontalFold: nil), .landscape)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 720, height: 800), horizontalFold: nil), .portrait)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 834, height: 1210), horizontalFold: nil), .portrait)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 744, height: 1133), horizontalFold: nil), .portrait)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 592, height: 834), horizontalFold: nil), .portrait)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 700, height: 600), horizontalFold: nil), .portrait)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: CGSize(width: 440, height: 956), horizontalFold: nil), .portrait)
    }

    @MainActor func testAWindowAgainstOneSideOfTheScreenIsReachedFromThatSide() {
        let screen = CGRect(x: 0, y: 0, width: 1194, height: 834)
        XCTAssertEqual(AdaptiveLayout.outerSide(window: CGRect(x: 0, y: 0, width: 798, height: 834), screen: screen), .left)
        XCTAssertEqual(AdaptiveLayout.outerSide(window: CGRect(x: 819, y: 0, width: 375, height: 834), screen: screen), .right)
        XCTAssertEqual(AdaptiveLayout.outerSide(window: CGRect(x: 0.5, y: 0, width: 600, height: 834), screen: screen), .left)
        XCTAssertNil(AdaptiveLayout.outerSide(window: screen, screen: screen))
        XCTAssertNil(AdaptiveLayout.outerSide(window: CGRect(x: 0, y: 0, width: 1194, height: 417), screen: screen))
        XCTAssertEqual(AdaptiveLayout.outerSide(window: CGRect(x: 360, y: 60, width: 818, height: 700), screen: screen), .right)
        XCTAssertEqual(AdaptiveLayout.outerSide(window: CGRect(x: 20, y: 60, width: 600, height: 700), screen: screen), .left)
        XCTAssertNil(AdaptiveLayout.outerSide(window: CGRect(x: 120, y: 80, width: 700, height: 600), screen: screen))
        XCTAssertNil(AdaptiveLayout.outerSide(window: CGRect(x: 30, y: 0, width: 1140, height: 834), screen: screen))
        XCTAssertNil(AdaptiveLayout.outerSide(window: .zero, screen: screen))
    }

    @MainActor func testControlsFollowTheThumbThatReachesTheWindow() {
        XCTAssertEqual(AdaptiveLayout.controlsSide(outer: nil, rightToLeft: false, otherwise: .trailing), .trailing)
        XCTAssertEqual(AdaptiveLayout.controlsSide(outer: nil, rightToLeft: true, otherwise: .leading), .leading)
        XCTAssertEqual(AdaptiveLayout.controlsSide(outer: .left, rightToLeft: false, otherwise: .trailing), .leading)
        XCTAssertEqual(AdaptiveLayout.controlsSide(outer: .right, rightToLeft: false, otherwise: .leading), .trailing)
        XCTAssertEqual(AdaptiveLayout.controlsSide(outer: .left, rightToLeft: true, otherwise: .leading), .trailing)
        XCTAssertEqual(AdaptiveLayout.controlsSide(outer: .right, rightToLeft: true, otherwise: .trailing), .leading)
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

    @MainActor func testMiniOnItsSideTakesTurnsBetweenSidebarAndColumn() {
        let sidebar: CGFloat = 280
        XCTAssertFalse(AdaptiveLayout.columnFitsBesideSidebar(width: 1158, sidebarWidth: sidebar))
        XCTAssertTrue(AdaptiveLayout.columnWaits(width: 1158, sidebarWidth: sidebar, turn: .sidebar))
        XCTAssertFalse(AdaptiveLayout.columnWaits(width: 1158, sidebarWidth: sidebar, turn: .column))
        XCTAssertFalse(AdaptiveLayout.columnWaits(width: 1158, sidebarWidth: 0, turn: .sidebar))
        XCTAssertTrue(AdaptiveLayout.usesSplit(size: CGSize(width: 1158, height: 756), style: .column))
    }

    @MainActor func testLargerIPadsKeepTheSidebarBesideTheColumn() {
        XCTAssertTrue(AdaptiveLayout.columnFitsBesideSidebar(width: 1194, sidebarWidth: 280))
        XCTAssertTrue(AdaptiveLayout.columnFitsBesideSidebar(width: 1210, sidebarWidth: 280))
        XCTAssertTrue(AdaptiveLayout.columnFitsBesideSidebar(width: 1376, sidebarWidth: 300))
        XCTAssertFalse(AdaptiveLayout.columnWaits(width: 1210, sidebarWidth: 280, turn: .sidebar))
    }

    @MainActor func testJumpBackInTakesThreeTilesOnAnUprightMini() {
        XCTAssertEqual(AdaptiveLayout.homeJumpColumns(contentWidth: 393), 2)
        XCTAssertEqual(AdaptiveLayout.homeJumpColumns(contentWidth: 669), 2)
        XCTAssertEqual(AdaptiveLayout.homeJumpColumns(contentWidth: 724), 3)
        XCTAssertEqual(AdaptiveLayout.homeJumpColumns(contentWidth: 756), 3)
    }

    @MainActor func testUprightIPadGivesTheCoverMoreOfTheHeight() {
        XCTAssertEqual(AdaptiveLayout.portraitArtworkShare(size: CGSize(width: 756, height: 1158), isColumnPane: false), 0.58)
        XCTAssertEqual(AdaptiveLayout.portraitArtworkShare(size: CGSize(width: 756, height: 1000), isColumnPane: false), 0.58)
        XCTAssertEqual(AdaptiveLayout.portraitArtworkShare(size: CGSize(width: 834, height: 1210), isColumnPane: false), 0.58)
        XCTAssertEqual(AdaptiveLayout.portraitArtworkShare(size: CGSize(width: 402, height: 874), isColumnPane: false), 0.42)
        XCTAssertEqual(AdaptiveLayout.portraitArtworkShare(size: CGSize(width: 669, height: 951), isColumnPane: false, hasFold: true), 0.42)
        XCTAssertEqual(AdaptiveLayout.portraitArtworkShare(size: CGSize(width: 360, height: 756), isColumnPane: true), 0.34)
    }
    @MainActor func testAnIPadColumnKeepsLyricsAndTheQueueInsideItLikeAPhone() {
        XCTAssertFalse(AdaptiveLayout.centerStateSpreadsPane(style: .column))
        XCTAssertTrue(AdaptiveLayout.centerStateSpreadsPane(style: .halves))
    }

    @MainActor func testASpreadPlayerUsesFocusPagesOnlyWhileLyricsOrTheQueueShow() {
        XCTAssertTrue(AdaptiveLayout.usesFocusArrangement(isSpread: true, showsArtwork: false))
        XCTAssertFalse(AdaptiveLayout.usesFocusArrangement(isSpread: true, showsArtwork: true))
        XCTAssertFalse(AdaptiveLayout.usesFocusArrangement(isSpread: false, showsArtwork: false))
        let window = CGSize(width: 1194, height: 834)
        let geometry = AdaptiveLayout.splitGeometry(width: window.width, division: nil)
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: window, horizontalFold: nil, focus: geometry), .focus(geometry))
        XCTAssertEqual(AdaptiveLayout.playerLayout(size: window, horizontalFold: nil, focus: nil), .landscape)
    }

    @MainActor func testAPaneThatEndsStaysOpenOnlyWhileSpreadWithASong() {
        XCTAssertTrue(AdaptiveLayout.compactKeepsPlayerExpanded(wasSpread: true, hasTrack: true))
        XCTAssertFalse(AdaptiveLayout.compactKeepsPlayerExpanded(wasSpread: true, hasTrack: false))
        XCTAssertFalse(AdaptiveLayout.compactKeepsPlayerExpanded(wasSpread: false, hasTrack: true))
    }

    @MainActor func testTheColumnOnlyExistsWhereItsControlsAreWithinTheRightThumb() {
        XCTAssertTrue(AdaptiveLayout.usesSplit(size: CGSize(width: 1194, height: 834), style: .column))
        XCTAssertTrue(AdaptiveLayout.usesSplit(size: CGSize(width: 1158, height: 756), style: .column))
        XCTAssertFalse(AdaptiveLayout.usesSplit(size: CGSize(width: 834, height: 1194), style: .column))
        XCTAssertFalse(AdaptiveLayout.usesSplit(size: CGSize(width: 834, height: 834), style: .column))
        let narrowestColumnWindow: CGFloat = 1120
        XCTAssertTrue(AdaptiveLayout.usesSplit(size: CGSize(width: narrowestColumnWindow, height: 834), style: .column))
        XCTAssertFalse(AdaptiveLayout.usesSplit(size: CGSize(width: narrowestColumnWindow - 1, height: 834), style: .column))
        let elevenInchScreen: CGFloat = 1194
        let transportFromRightEdge = elevenInchScreen - narrowestColumnWindow
            + AdaptiveLayout.playerColumnWidth(forWidth: narrowestColumnWindow) / 2
        XCTAssertLessThanOrEqual(transportFromRightEdge, 300)
    }
}
