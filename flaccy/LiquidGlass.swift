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

    /// A fixed-height glass capsule hosting the given control, with a solid-fill
    /// fallback when Reduce Transparency is enabled.
    static func capsule(hosting control: UIView, height: CGFloat = 44) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let background: UIView
        if UIAccessibility.isReduceTransparencyEnabled {
            let solid = UIView()
            solid.backgroundColor = UIColor.white.withAlphaComponent(0.16)
            solid.layer.cornerRadius = height / 2
            solid.layer.cornerCurve = .continuous
            solid.clipsToBounds = true
            background = solid
        } else {
            background = view(cornerRadius: height / 2, interactive: true)
        }
        background.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(background)
        container.addSubview(control)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: height),
            background.topAnchor.constraint(equalTo: container.topAnchor),
            background.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            control.topAnchor.constraint(equalTo: container.topAnchor),
            control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            control.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
}
