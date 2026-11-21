import FlaccyCore
import ObjectiveC
import QuartzCore

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
    /// are, down to square, and exactly as asked for under standard corners.
    static func radius(_ radius: CGFloat) -> CGFloat {
        corners == ThemePack.cornersStandard ? radius : (radius * CGFloat(corners)).rounded()
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
