import FlaccyCore
import ObjectiveC
import UIKit

/// The shapes of the worn theme: how round the app's own corners are and what
/// shape a cover takes.
@MainActor
enum ThemeShape {

    private(set) static var corners = ThemePack.cornersStandard
    private(set) static var covers = ThemePack.CoverShape.rounded
    private(set) static var shadows = true

    static func wear(_ look: ThemeLook) {
        corners = look.corners
        covers = look.covers
        shadows = look.shadows
    }

    /// `radius` as the worn theme draws it: scaled by how round its corners
    /// are, down to square.
    static func radius(_ radius: CGFloat) -> CGFloat {
        (radius * CGFloat(corners)).rounded()
    }

    /// The corner radius of a cover `side` points wide whose own radius is
    /// `radius`: half its side for a round cover, none for a square one.
    static func coverRadius(_ radius: CGFloat, side: CGFloat) -> CGFloat {
        switch covers {
        case .rounded: ThemeShape.radius(radius)
        case .square: 0
        case .circle: side / 2
        }
    }
}

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

extension CALayer {

    private nonisolated(unsafe) static var baseRadiusKey: UInt8 = 0
    private nonisolated(unsafe) static var shadowKey: UInt8 = 0

    /// A corner radius the worn theme may scale. The radius as it was asked
    /// for is remembered, so another theme scales from it and not from what
    /// the last one made of it.
    @MainActor
    var themedCornerRadius: CGFloat {
        get { (objc_getAssociatedObject(self, &CALayer.baseRadiusKey) as? CGFloat) ?? cornerRadius }
        set {
            objc_setAssociatedObject(self, &CALayer.baseRadiusKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            cornerRadius = ThemeShape.radius(newValue)
        }
    }

    @MainActor
    func reapplyThemedCornerRadius() {
        guard let base = objc_getAssociatedObject(self, &CALayer.baseRadiusKey) as? CGFloat else { return }
        let scaled = ThemeShape.radius(base)
        if cornerRadius != scaled { cornerRadius = scaled }
    }

    /// The shadow opacity a cover's host was built with, kept so a theme
    /// without shadows can take it away and another can give it back.
    @MainActor
    var themedShadowOpacity: Float {
        if let stored = objc_getAssociatedObject(self, &CALayer.shadowKey) as? Float { return stored }
        objc_setAssociatedObject(self, &CALayer.shadowKey, shadowOpacity, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return shadowOpacity
    }
}
