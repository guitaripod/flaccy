import AppKit
import FlaccyCore
import ObjectiveC

/// Keeps one cover in the shape the worn theme gives covers, whatever size it
/// is laid out at: a round cover's radius is half its side, and a tile is
/// sized long after it is made.
@MainActor
final class MacCoverShaper: NSObject {

    private weak var cover: NSView?

    /// The radius the cover has when the theme leaves covers rounded.
    var radius: CGFloat {
        didSet { shape() }
    }

    /// A cover drawn bare, edge to edge, as in a wall: square.
    var isBare = false {
        didSet { shape() }
    }

    /// A picture that is not a cover, as an artist's photo: it keeps the
    /// radius it was given whatever shape the theme gives covers.
    var keepsOwnShape = false {
        didSet { shape() }
    }

    /// The radius the cover is drawn with now.
    private(set) var shownRadius: CGFloat = 0

    init(cover: NSView, radius: CGFloat) {
        self.cover = cover
        self.radius = radius
        super.init()
        cover.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: cover
        )
        shape()
    }

    @objc private func frameChanged() {
        shape()
    }

    func shape() {
        guard let cover, let layer = cover.layer else { return }
        let side = min(cover.bounds.width, cover.bounds.height)
        let shaped = keepsOwnShape ? radius : (isBare ? 0 : ThemeShape.coverRadius(radius, side: side))
        shownRadius = shaped
        if layer.cornerRadius != shaped { layer.cornerRadius = shaped }
        layer.cornerCurve = ThemeShape.covers == .circle && !isBare && !keepsOwnShape ? .circular : .continuous
    }
}

extension NSView {

    private nonisolated(unsafe) static var coverShaperKey: UInt8 = 0

    /// The shaper of a view that was made a cover with `shapeAsCover`.
    var macCoverShaper: MacCoverShaper? {
        objc_getAssociatedObject(self, &NSView.coverShaperKey) as? MacCoverShaper
    }

    /// Makes this view a cover: rounded by `radius` under a theme that leaves
    /// covers rounded, square or round under one that says so. Calling it
    /// again changes the radius.
    func shapeAsCover(radius: CGFloat) {
        if let shaper = macCoverShaper {
            shaper.radius = radius
            return
        }
        wantsLayer = true
        let shaper = MacCoverShaper(cover: self, radius: radius)
        objc_setAssociatedObject(self, &NSView.coverShaperKey, shaper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
