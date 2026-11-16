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
    static let playerContentMaximumWidth: CGFloat = 640
    static let playerControlsMaximumWidth: CGFloat = 560
    static let playerRoomyPortraitMinimumHeight: CGFloat = 700
    static let playerRoomyLandscapeMinimumHeight: CGFloat = 500
    static let paneQueueMinimumHeight: CGFloat = 150
    static let badgesBesideTitleMinimumWidth: CGFloat = 300
    static let actionRowSingleLineMinimumWidth: CGFloat = 310

    static let homeWideMinimumWidth: CGFloat = 760
    static let homeWideJumpColumns = 3

    /// Whether Home has room for its iPad-class arrangement, judged from the
    /// width its own content area was given, never from the device.
    static func homeIsWide(contentWidth: CGFloat) -> Bool {
        contentWidth >= homeWideMinimumWidth
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
    static func playerLayout(
        size: CGSize, horizontalFold: ClosedRange<CGFloat>?, focus: SplitGeometry? = nil
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
        return .portrait
    }
}

extension UIView {

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
