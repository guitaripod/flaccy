import CoreGraphics
import UIKit

/// The numbers behind every width- and fold-dependent layout decision in the
/// iPhone client, kept free of view code so they can be tested and so no screen
/// derives its own thresholds. Nothing here asks what device this is: every
/// answer comes from the size a view was actually given and from the fold
/// region the system reports for it.
enum AdaptiveLayout {

    static let splitMinimumWidth: CGFloat = 840
    static let splitMinimumHeight: CGFloat = 560

    static let playerColumnMinimumWidth: CGFloat = 360
    static let playerColumnMaximumWidth: CGFloat = 440
    static let playerColumnWidthFraction: CGFloat = 0.3
    static let columnLibraryMinimumWidth: CGFloat = 760

    static let gridTargetTileWidth: CGFloat = 160
    static let gridMinimumColumns = 3
    static let evenColumnsFromWidth: CGFloat = 500

    static let detailSideBySideMinimumWidth: CGFloat = 560
    static let detailBannerWideMinimumWidth: CGFloat = 560
    static let detailBannerMinimumWidth: CGFloat = 340
    static let detailStackedMinimumHeight: CGFloat = 760

    static let playerLandscapeMaximumHeight: CGFloat = 560
    static let playerWideLandscapeMinimumWidth: CGFloat = 1000
    static let playerSideBySideMinimumWidth: CGFloat = 720
    static let playerSideBySideMinimumAspect: CGFloat = 0.9
    static let playerContentMaximumWidth: CGFloat = 640
    static let playerControlsMaximumWidth: CGFloat = 560
    static let playerSideControlsMaximumWidth: CGFloat = 440
    static let playerSideControlsMinimumWidth: CGFloat = 340
    static let playerSideMargins: CGFloat = 84
    static let playerLandscapeArtworkShare: CGFloat = 0.72
    static let playerPortraitColumnMargins: CGFloat = 56
    static let playerRoomyPortraitMinimumHeight: CGFloat = 700
    static let playerRoomyLandscapeMinimumHeight: CGFloat = 500
    static let paneQueueMinimumHeight: CGFloat = 150
    static let badgesBesideTitleMinimumWidth: CGFloat = 300

    static let homeWideMinimumWidth: CGFloat = 760
    static let homeWideJumpColumns = 3
    static let homeThreeJumpColumnsMinimumWidth: CGFloat = 700

    static let columnLibraryBesideSidebarMinimum: CGFloat = 540

    static let playerTallPortraitMinimumWidth: CGFloat = 600
    static let playerTallPortraitMinimumHeight: CGFloat = 900

    /// Whether Home has room for its iPad-class arrangement, judged from the
    /// width its own content area was given, never from the device.
    static func homeIsWide(contentWidth: CGFloat) -> Bool {
        contentWidth >= homeWideMinimumWidth
    }

    /// How many tiles Jump Back In lays side by side: three beside the hero on
    /// a wide Home, three under it once the page is as wide as an upright iPad
    /// mini, where two tiles each half the page wide were mostly empty grey,
    /// and two on a phone, where three would break the titles.
    static func homeJumpColumns(contentWidth: CGFloat) -> Int {
        contentWidth >= homeThreeJumpColumnsMinimumWidth ? homeWideJumpColumns : 2
    }

    /// Whether the library keeps `columnLibraryBesideSidebarMinimum` between a
    /// docked sidebar `sidebarWidth` wide and the Now Playing column. A 13-inch
    /// or an 11-inch held sideways keeps it; an iPad mini on its side leaves
    /// the library about 520 pt there, the middle of three crowded panes.
    static func columnFitsBesideSidebar(width: CGFloat, sidebarWidth: CGFloat) -> Bool {
        guard sidebarWidth > 0 else { return true }
        return width - sidebarWidth - playerColumnWidth(forWidth: width) >= columnLibraryBesideSidebarMinimum
    }

    /// Which of the two side panes has the room when a docked sidebar and the
    /// Now Playing column cannot both stand beside the library: the one the
    /// person brought out last.
    enum SideTurn: Equatable {
        case sidebar
        case column
    }

    /// Whether the Now Playing column waits for its turn in a window that
    /// could otherwise show it: only while a docked sidebar would leave the
    /// library too narrow beside it and the sidebar has the turn. The mini
    /// player carries playback meanwhile.
    static func columnWaits(width: CGFloat, sidebarWidth: CGFloat, turn: SideTurn) -> Bool {
        turn == .sidebar && !columnFitsBesideSidebar(width: width, sidebarWidth: sidebarWidth)
    }

    /// How much of the view's height the cover may take in the single column:
    /// the Now Playing column keeps room for its title and Up Next, a phone
    /// keeps room for its controls, and an iPad held upright, a mini included,
    /// has height to spare above the controls and gives it to the cover. A
    /// display a fold runs across keeps the phone's share, so the cover never
    /// grows over the hinge of a Duo opened flat.
    static func portraitArtworkShare(size: CGSize, isColumnPane: Bool, hasFold: Bool = false) -> CGFloat {
        if isColumnPane { return 0.34 }
        if !hasFold, size.width >= playerTallPortraitMinimumWidth, size.height >= playerTallPortraitMinimumHeight {
            return 0.58
        }
        return 0.42
    }

    /// How a window that holds the library beside Now Playing divides. A
    /// window a fold runs down (an iPhone Duo's inner display on its side)
    /// splits into halves that end at the fold; any other window gives Now
    /// Playing a column along the trailing edge and the library the rest.
    /// The fold the system reports decides, never the device.
    enum SplitStyle: Equatable {
        case halves
        case column

        init(division: CGRect?) {
            guard let division, division.height > division.width, division.width > 0 else {
                self = .column
                return
            }
            self = .halves
        }
    }

    /// Whether the window is big enough to hold the library beside Now Playing.
    /// Both sides are required so a Pro Max held sideways, which is wide but
    /// short, keeps the single-pane player. A column split also needs the
    /// library to keep `columnLibraryMinimumWidth` beside the player column.
    static func usesSplit(size: CGSize, style: SplitStyle = .halves) -> Bool {
        guard size.height >= splitMinimumHeight else { return false }
        switch style {
        case .halves: return size.width >= splitMinimumWidth
        case .column: return size.width - playerColumnWidth(forWidth: size.width) >= columnLibraryMinimumWidth
        }
    }

    /// Whether opening lyrics or the queue spreads a player pane over the whole
    /// window. Halves that end at a fold do: the cover keeps one page and the
    /// words take the facing one (the iPhone Duo's focus). An iPad's column
    /// does not: it is the iPhone's player at the iPhone's width, so lyrics and
    /// the queue open inside it, as they do on a phone, and the library stays
    /// beside them to browse while they play. Spreading a column is the
    /// person's own choice (its expand button, ⇧⌘F).
    static func centerStateSpreadsPane(style: SplitStyle) -> Bool {
        style == .halves
    }

    /// Whether a player pane that stops being a pane stays open over the window:
    /// only when it was spread and there is still a song, so a window narrowed
    /// under a spread player keeps it open, and a queue that ran out never
    /// leaves an empty player over the library.
    static func compactKeepsPlayerExpanded(wasSpread: Bool, hasTrack: Bool) -> Bool {
        wasSpread && hasTrack
    }

    /// Whether a player that has the whole window arranges the cover on one
    /// side and lyrics or the queue on the other: only while one of them is
    /// showing. A spread player showing its cover uses the whole-window layout
    /// of its size instead (the cover beside the controls on a wide window),
    /// never a focus page with nothing on it.
    static func usesFocusArrangement(isSpread: Bool, showsArtwork: Bool) -> Bool {
        isSpread && !showsArtwork
    }

    /// Whether Now Playing has a pane of its own right now: the window has
    /// room for one, something is playing, and the person has not hidden it.
    /// With nothing to play the library keeps the whole window instead of
    /// sharing it with an empty player.
    static func showsPlayerPane(size: CGSize, style: SplitStyle, hasTrack: Bool, isShown: Bool) -> Bool {
        hasTrack && isShown && usesSplit(size: size, style: style)
    }

    struct SplitGeometry: Equatable {
        let primaryWidth: CGFloat
        let secondaryLeading: CGFloat
    }

    /// Where the library ends and Now Playing begins. With a fold reported for
    /// the window the panes end at its edges, so each half stands on its own
    /// and nothing straddles the hinge; without one, halves meet at a fixed
    /// gutter around the centre and a column takes `playerColumnWidth(forWidth:)`
    /// along the trailing edge.
    static func splitGeometry(width: CGFloat, division: CGRect?, style: SplitStyle = .halves) -> SplitGeometry {
        if let fold = verticalFold(division) {
            return SplitGeometry(primaryWidth: fold.minX, secondaryLeading: fold.maxX)
        }
        switch style {
        case .halves:
            let gutter: CGFloat = 40
            let primary = (width / 2 - gutter / 2).rounded(.down)
            return SplitGeometry(primaryWidth: primary, secondaryLeading: primary + gutter)
        case .column:
            let primary = width - playerColumnWidth(forWidth: width)
            return SplitGeometry(primaryWidth: primary, secondaryLeading: primary)
        }
    }

    /// The Now Playing column's width beside the library: a share of the
    /// window, never narrower than the controls need nor so wide that it
    /// starves the library.
    static func playerColumnWidth(forWidth width: CGFloat) -> CGFloat {
        min(max((width * playerColumnWidthFraction).rounded(.down), playerColumnMinimumWidth), playerColumnMaximumWidth)
    }

    private static func verticalFold(_ division: CGRect?) -> CGRect? {
        guard let division, division.height > division.width, division.width > 0 else { return nil }
        return division
    }

    /// Cover-wall column count for a container of this width. Phone widths keep
    /// the established three columns; from `evenColumnsFromWidth` up the count
    /// is always even so a grid that fills a wide window divides cleanly across
    /// a centred vertical fold.
    static func gridColumns(forWidth width: CGFloat) -> Int {
        guard width >= evenColumnsFromWidth else { return gridMinimumColumns }
        let fitted = max(2, Int((width / gridTargetTileWidth).rounded(.down)))
        return fitted + fitted % 2
    }

    /// A grid a vertical fold divides: one column count on each side and one
    /// tile width on both, with the fold itself as the gap between the two
    /// middle columns, so in the book pose no tile lies across the hinge.
    struct FoldGrid: Equatable {
        let columnsPerSide: Int
        let sideWidth: CGFloat
        /// The fold's own width, the gap between the two halves.
        let gap: CGFloat
        /// What the grid adds to the section's usual leading and trailing
        /// insets so its two halves meet at the fold. The wider side gives up
        /// the difference, which mirrors a vertical bar on the other edge.
        let extraLeading: CGFloat
        let extraTrailing: CGFloat
    }

    static let foldGridMinimumSide: CGFloat = 200

    /// The fold grid for content spanning `content` (x, in the view's own
    /// space, after the section's usual insets) with a vertical fold over
    /// `fold`, or nil when there is no fold or it leaves either side too
    /// narrow. Each side takes the column count a grid of its width would
    /// have, as on a phone.
    static func foldGrid(
        content: ClosedRange<CGFloat>, fold: ClosedRange<CGFloat>?, columnsForSide: @MainActor (CGFloat) -> Int
    ) -> FoldGrid? {
        guard let fold, fold.lowerBound > content.lowerBound, fold.upperBound < content.upperBound else { return nil }
        let leading = fold.lowerBound - content.lowerBound
        let trailing = content.upperBound - fold.upperBound
        let side = min(leading, trailing)
        guard side >= foldGridMinimumSide else { return nil }
        return FoldGrid(
            columnsPerSide: max(1, columnsForSide(side)), sideWidth: side, gap: fold.upperBound - fold.lowerBound,
            extraLeading: leading - side, extraTrailing: trailing - side
        )
    }

    /// A row of two parts that meets a fold running down it: the leading part
    /// ends where the fold begins and the trailing part starts where it ends,
    /// so each stands on its own page in the book pose.
    struct FoldHalves: Equatable {
        let leading: CGFloat
        let trailing: CGFloat
        let gap: CGFloat
    }

    /// The halves for content spanning `content` (x, in the view's own space)
    /// with a vertical fold over `fold`, or nil when there is no fold or either
    /// part would be narrower than its minimum.
    static func foldHalves(
        content: ClosedRange<CGFloat>, fold: ClosedRange<CGFloat>?, leadingMinimum: CGFloat, trailingMinimum: CGFloat
    ) -> FoldHalves? {
        guard let fold else { return nil }
        let leading = fold.lowerBound - content.lowerBound
        let trailing = content.upperBound - fold.upperBound
        guard leading >= leadingMinimum, trailing >= trailingMinimum else { return nil }
        return FoldHalves(leading: leading, trailing: trailing, gap: fold.upperBound - fold.lowerBound)
    }

    static let shelfTargetTileWidth: CGFloat = 190

    /// Album shelf column count on an artist page: two on a phone, then an
    /// even count that grows with the width.
    static func shelfColumns(forWidth width: CGFloat) -> Int {
        let fitted = max(2, Int((width / shelfTargetTileWidth).rounded(.down)))
        return fitted + fitted % 2
    }

    enum DetailHeaderStyle: Equatable {
        case stacked
        case banner
        case sideBySide
    }

    /// How an album or playlist page arranges its artwork against its rows.
    static func detailHeaderStyle(forSize size: CGSize) -> DetailHeaderStyle {
        if size.width >= detailSideBySideMinimumWidth, size.width >= size.height * 1.1 { return .sideBySide }
        if size.width >= detailBannerWideMinimumWidth { return .banner }
        if size.width >= detailBannerMinimumWidth, size.height < detailStackedMinimumHeight { return .banner }
        return .stacked
    }

    static let mediaClearanceGap: CGFloat = 12
    static let mediaClearanceMinimumWidth: CGFloat = 160

    /// How the cover of a pane may use the band a corner cutout reserves. A
    /// view whose top is inset only because something sits in one corner (the
    /// iPhone Duo's status cluster over the Now Playing half) need not lose
    /// that whole band: the cover can rise into it as long as it stays clear
    /// of the corner sideways.
    struct MediaClearance: Equatable {
        /// How far above the safe area the media may start.
        var rise: CGFloat
        /// The room the cover keeps from the column's leading and trailing edges.
        var leading: CGFloat
        var trailing: CGFloat

        static let none = MediaClearance(rise: 0, leading: 0, trailing: 0)
    }

    /// The clearance for a column spanning `column` (x, in the view's own
    /// space) under a top inset of `safeTop`, given the active occlusions the
    /// system reports for the view. Nothing changes when no occlusion explains
    /// the inset, when one covers the column's centre, or when the cover would
    /// be left narrower than `mediaClearanceMinimumWidth`.
    static func mediaClearance(column: ClosedRange<CGFloat>, safeTop: CGFloat, occlusions: [CGRect]) -> MediaClearance {
        guard safeTop > 0 else { return .none }
        let band = occlusions.filter { $0.minY < safeTop && $0.width > 0 && $0.height > 0 }
        guard !band.isEmpty else { return .none }
        let center = (column.lowerBound + column.upperBound) / 2
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
        for region in band {
            guard region.maxX > column.lowerBound, region.minX < column.upperBound else { continue }
            if region.minX <= center, region.maxX >= center { return .none }
            if region.maxX < center {
                leading = max(leading, region.maxX + mediaClearanceGap - column.lowerBound)
            } else {
                trailing = max(trailing, column.upperBound - (region.minX - mediaClearanceGap))
            }
        }
        let width = column.upperBound - column.lowerBound - leading - trailing
        guard width >= mediaClearanceMinimumWidth else { return .none }
        return MediaClearance(rise: safeTop, leading: leading, trailing: trailing)
    }

    enum PlayerLayout: Equatable {
        case portrait
        case landscape
        case laptop(foldTop: CGFloat, foldBottom: CGFloat)
        case focus(SplitGeometry)
    }

    /// The Now Playing arrangement for a view of this size. With focus asked
    /// for on a window wide enough to split, the artwork takes the left half
    /// and lyrics or the queue the right half over the controls, each ending at
    /// the fold. A fold running
    /// across the view puts artwork and lyrics in the region above it and the
    /// controls in the stable region below; a short, wide view, or one wide
    /// enough to hold a full-size cover beside the controls (an iPad's whole
    /// window), puts the artwork beside the controls; everything else is the
    /// single column.
    ///
    /// A window with no fold (an iPad's) also puts the cover beside the
    /// controls once it is about as wide as it is tall and the cover beside
    /// the controls comes out at least as large as above them, such as two
    /// thirds of a landscape iPad or the top half of a portrait one: there the
    /// single column shrank the cover to a thumbnail above controls stretched
    /// across the window. A foldable's inner display keeps the rules its fold
    /// decides.
    static func playerLayout(
        size: CGSize, horizontalFold: ClosedRange<CGFloat>?, focus: SplitGeometry? = nil, hasFold: Bool = false
    ) -> PlayerLayout {
        if let focus, size.width >= splitMinimumWidth, size.height >= splitMinimumHeight {
            return .focus(focus)
        }
        if let horizontalFold, size.height > size.width {
            return .laptop(foldTop: horizontalFold.lowerBound, foldBottom: horizontalFold.upperBound)
        }
        if size.width > size.height * 1.15,
           size.height <= playerLandscapeMaximumHeight || size.width >= playerWideLandscapeMinimumWidth {
            return .landscape
        }
        if !hasFold, size.width >= playerSideBySideMinimumWidth,
           size.width >= size.height * playerSideBySideMinimumAspect,
           sideBySideCover(size: size) >= portraitCover(size: size, hasFold: hasFold) {
            return .landscape
        }
        return .portrait
    }

    /// How the landscape player shares its width between the centre (the
    /// cover, the lyrics or the queue) and the controls. A short window (a
    /// phone on its side) keeps the phone's proportions, the cover a little
    /// over a third of the width and lyrics or the queue half; anything taller
    /// gives the controls a column against the edge the thumb reaches, wide
    /// enough to read and no wider than the cover can spare.
    enum LandscapeSplit: Equatable {
        case proportional
        case sideColumn(controlsWidth: CGFloat)

        var isSideColumn: Bool {
            if case .sideColumn = self { return true }
            return false
        }
    }

    static func landscapeSplit(size: CGSize) -> LandscapeSplit {
        guard size.height > playerLandscapeMaximumHeight else { return .proportional }
        return .sideColumn(controlsWidth: playerSideControlsWidth(size: size))
    }

    /// The side controls column's width: its full 440 pt where the cover is
    /// held back by the height anyway, narrowing to 340 pt so a window about
    /// as wide as it is tall still gives the cover the room it would have had
    /// above the controls.
    static func playerSideControlsWidth(size: CGSize) -> CGFloat {
        let besideFullCover = size.width - playerSideMargins - size.height * playerLandscapeArtworkShare
        return min(playerSideControlsMaximumWidth, max(playerSideControlsMinimumWidth, besideFullCover))
    }

    /// The cover's side when it stands beside the side controls column.
    static func sideBySideCover(size: CGSize) -> CGFloat {
        let centre = size.width - playerSideMargins - playerSideControlsWidth(size: size)
        return max(0, min(centre, size.height * playerLandscapeArtworkShare))
    }

    /// The cover's side in the whole-window single column of the same size.
    static func portraitCover(size: CGSize, hasFold: Bool) -> CGFloat {
        let column = min(size.width - playerPortraitColumnMargins, playerContentMaximumWidth)
        let share = portraitArtworkShare(size: size, isColumnPane: false, hasFold: hasFold)
        return max(0, min(column, size.height * share))
    }

    /// A physical side of the screen, whatever the writing direction.
    enum ScreenSide: Equatable {
        case left
        case right
    }

    /// A side of a view in its own writing direction.
    enum Side: Equatable {
        case leading
        case trailing
    }

    static let screenEdgeReach: CGFloat = 48

    /// The one side edge of the screen a window lies against or close beside,
    /// or nil when it reaches both (the whole screen, a full-width top or
    /// bottom half) or neither (a window floating in the middle). Held in both
    /// hands, the thumb on that side is the one that reaches the window
    /// without crossing the app beside it.
    static func outerSide(window: CGRect, screen: CGRect) -> ScreenSide? {
        guard window.width > 0, screen.width > 0 else { return nil }
        let left = window.minX <= screen.minX + screenEdgeReach
        let right = window.maxX >= screen.maxX - screenEdgeReach
        switch (left, right) {
        case (true, false): return .left
        case (false, true): return .right
        default: return nil
        }
    }

    /// Where a window's frequent controls go: against the screen edge the
    /// window shares with the thumb that reaches it, and where they would go
    /// anyway when the window spans the screen or floats.
    static func controlsSide(outer: ScreenSide?, rightToLeft: Bool, otherwise: Side) -> Side {
        switch (outer, rightToLeft) {
        case (nil, _): return otherwise
        case (.left, false), (.right, true): return .leading
        case (.right, false), (.left, true): return .trailing
        }
    }
}

extension UIView {

    /// The one side edge of the screen this view's window lies against, read
    /// from where the window sits on the screen right now; nil for a window
    /// that spans the screen, floats clear of both sides, or has none yet.
    var outerScreenSide: AdaptiveLayout.ScreenSide? {
        guard let window, let screen = window.windowScene?.screen else { return nil }
        let frame = window.convert(window.bounds, to: screen.coordinateSpace)
        return AdaptiveLayout.outerSide(window: frame, screen: screen.bounds)
    }

    /// Where this view's frequent controls go for the window it is in, with
    /// `otherwise` for a window that spans the screen or floats.
    func reachableControlsSide(otherwise: AdaptiveLayout.Side) -> AdaptiveLayout.Side {
        AdaptiveLayout.controlsSide(
            outer: outerScreenSide, rightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft, otherwise: otherwise
        )
    }

    /// The fold region in this view's own coordinate space, whether or not the
    /// device is folded right now, or nil where the system reports none (the
    /// outer display, an iPhone without a hinge, an SDK older than 27.1).
    /// Read on every layout pass: regions arrive after the first one.
    var divisionRegionFrame: CGRect? {
        #if canImport(UIKit, _version: 9127.0.85)
        if #available(iOS 27.1, *) {
            return reservedRegions(kind: .division, options: [.includeInactive]).first?.frame
        }
        #endif
        return nil
    }

    /// The occlusions the system reports in this view's own space that are in
    /// effect right now, such as the iPhone Duo's status cluster; none where
    /// nothing is reported or before iOS 27.1.
    var activeOcclusionFrames: [CGRect] {
        #if canImport(UIKit, _version: 9127.0.85)
        if #available(iOS 27.1, *) {
            return reservedRegions(kind: .occlusion, options: []).filter(\.isActive).map(\.frame)
        }
        #endif
        return []
    }

    /// The horizontal extent of a fold that runs down this view, inactive or
    /// not, when it lies inside the view's bounds; nil on the outer display,
    /// on a pane that ends at the fold, and on devices without one.
    var verticalFoldSpan: ClosedRange<CGFloat>? {
        guard let frame = divisionRegionFrame, frame.height > frame.width, frame.width > 0,
              frame.minX > bounds.minX, frame.maxX < bounds.maxX else { return nil }
        return frame.minX...frame.maxX
    }

    /// The vertical extent of a fold that runs across this view, or nil when
    /// the fold is absent or runs the other way. Only an active fold counts: a
    /// flat device keeps the layout it already has.
    var activeHorizontalFold: ClosedRange<CGFloat>? {
        #if canImport(UIKit, _version: 9127.0.85)
        if #available(iOS 27.1, *) {
            let regions = reservedRegions(kind: .division, options: [])
            guard let frame = regions.first(where: { $0.isActive })?.frame,
                  frame.width > frame.height else { return nil }
            return frame.minY...frame.maxY
        }
        #endif
        return nil
    }
}
