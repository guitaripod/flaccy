import UIKit

/// Liquid Glass material with a graceful fallback to a blur on iOS 18–25.
enum LiquidGlass {

    /// A glass (iOS 26+) or thick-material blur effect for custom surfaces.
    static func effect(interactive: Bool = false, tint: UIColor? = nil) -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = interactive
            if let tint { glass.tintColor = tint }
            return glass
        }
        return UIBlurEffect(style: .systemThickMaterial)
    }

    /// A visual-effect view backed by Liquid Glass, with continuous-corner clipping.
    static func view(cornerRadius: CGFloat, interactive: Bool = false, tint: UIColor? = nil) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: effect(interactive: interactive, tint: tint))
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        return view
    }
}
