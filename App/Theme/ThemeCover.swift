import FlaccyCore
import ObjectiveC
import UIKit

/// Keeps one cover in the shape the worn theme gives covers, whatever size it
/// is laid out at: it watches the cover's bounds, since a round cover's radius
/// is half its side and a cell is sized long after it is made.
@MainActor
final class CoverShaper: NSObject {

    private weak var cover: UIView?
    private weak var shadowHost: UIView?
    private var observation: NSKeyValueObservation?

    /// The radius the cover has when the theme leaves covers rounded.
    var radius: CGFloat {
        didSet { shape() }
    }

    /// A cover drawn bare, edge to edge, as in a wall: square, no shadow.
    var isBare = false {
        didSet { shape() }
    }

    init(cover: UIView, radius: CGFloat, shadowHost: UIView?) {
        self.cover = cover
        self.radius = radius
        self.shadowHost = shadowHost
        super.init()
        observation = cover.layer.observe(\.bounds) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.shape() }
        }
        shape()
    }

    /// Shapes the cover for its size now, and its shadow with it: the shadow
    /// follows the same outline and goes when the theme has none.
    func shape() {
        guard let cover else { return }
        let side = min(cover.bounds.width, cover.bounds.height)
        let shaped = isBare ? 0 : ThemeShape.coverRadius(radius, side: side)
        if cover.layer.cornerRadius != shaped { cover.layer.cornerRadius = shaped }
        cover.layer.cornerCurve = ThemeShape.covers == .circle && !isBare ? .circular : .continuous
        guard let shadowHost else { return }
        let outline = shadowHost.convert(cover.bounds, from: cover)
        shadowHost.layer.shadowPath = UIBezierPath(roundedRect: outline, cornerRadius: shaped).cgPath
        shadowHost.layer.shadowOpacity = ThemeShape.shadows && !isBare ? shadowHost.layer.themedShadowOpacity : 0
    }
}

extension UIView {

    private nonisolated(unsafe) static var coverShaperKey: UInt8 = 0

    /// The shaper of a view that was made a cover with `shapeAsCover`.
    var coverShaper: CoverShaper? {
        objc_getAssociatedObject(self, &UIView.coverShaperKey) as? CoverShaper
    }

    /// Makes this view a cover: rounded by `radius` under a theme that leaves
    /// covers rounded, square or round under one that says so. `shadowHost` is
    /// the view that casts its shadow. Calling it again changes the radius.
    func shapeAsCover(radius: CGFloat, shadowHost: UIView? = nil) {
        if let shaper = coverShaper {
            shaper.radius = radius
            return
        }
        let shaper = CoverShaper(cover: self, radius: radius, shadowHost: shadowHost)
        objc_setAssociatedObject(self, &UIView.coverShaperKey, shaper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
