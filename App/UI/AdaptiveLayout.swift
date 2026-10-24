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

    static let gridTargetTileWidth: CGFloat = 160
    static let gridMinimumColumns = 3
    static let evenColumnsFromWidth: CGFloat = 500

    static let detailSideBySideMinimumWidth: CGFloat = 560
    static let detailBannerWideMinimumWidth: CGFloat = 560
    static let detailBannerMinimumWidth: CGFloat = 340
    static let detailStackedMinimumHeight: CGFloat = 760

    static let playerLandscapeMaximumHeight: CGFloat = 560

    /// Whether the window is big enough to hold the library beside Now Playing.
    /// Both sides are required so a Pro Max held sideways, which is wide but
    /// short, keeps the single-pane player.
    static func usesSplit(size: CGSize) -> Bool {
        size.width >= splitMinimumWidth && size.height >= splitMinimumHeight
    }

    struct SplitGeometry: Equatable {
        let primaryWidth: CGFloat
        let secondaryLeading: CGFloat
    }

    /// Where the two panes meet. With a fold reported for the window the panes
    /// end at its edges, so each half stands on its own and nothing straddles
    /// the hinge; without one they meet at a fixed gutter around the centre.
    static func splitGeometry(width: CGFloat, division: CGRect?) -> SplitGeometry {
        if let division, division.height > division.width, division.width > 0 {
            return SplitGeometry(primaryWidth: division.minX, secondaryLeading: division.maxX)
        }
        let gutter: CGFloat = 40
        let primary = (width / 2 - gutter / 2).rounded(.down)
        return SplitGeometry(primaryWidth: primary, secondaryLeading: primary + gutter)
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
    /// controls in the stable region below; a short, wide view puts the artwork
    /// beside the controls; everything else is the single column.
    static func playerLayout(
        size: CGSize, horizontalFold: ClosedRange<CGFloat>?, focus: SplitGeometry? = nil
    ) -> PlayerLayout {
        if let focus, size.width >= splitMinimumWidth, size.height >= splitMinimumHeight {
            return .focus(focus)
        }
        if let horizontalFold, size.height > size.width {
            return .laptop(foldTop: horizontalFold.lowerBound, foldBottom: horizontalFold.upperBound)
        }
        if size.width > size.height * 1.15, size.height <= playerLandscapeMaximumHeight {
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
