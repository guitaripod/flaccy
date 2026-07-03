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

extension LiquidGlass {

    /// Wraps a view whose subtree contains multiple glass capsules in a
    /// UIGlassContainerEffect on iOS 26 so adjacent glass shapes merge and morph
    /// as one group; on earlier systems the view is returned unchanged.
    static func grouping(_ content: UIView) -> UIView {
        guard #available(iOS 26.0, *), !UIAccessibility.isReduceTransparencyEnabled else {
            return content
        }
        let container = UIVisualEffectView(effect: UIGlassContainerEffect())
        content.translatesAutoresizingMaskIntoConstraints = false
        container.contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.contentView.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor),
        ])
        return container
    }

    /// A glass capsule wrapping a titled action button, sized for detail-screen
    /// action rows, with white foreground and light-impact haptics on tap.
    static func actionCapsule(
        title: String,
        systemImage: String,
        height: CGFloat = 48,
        action: @escaping () -> Void
    ) -> UIView {
        let button = makeActionButton(systemImage: systemImage, action: action)
        button.configuration?.title = title
        button.configuration?.imagePadding = 6
        button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .scaled(.subheadline, size: 15, weight: .semibold)
            return outgoing
        }
        return capsule(hosting: button, height: height)
    }

    /// A glass capsule wrapping an icon-only action button; `accessibilityLabel`
    /// names the action for VoiceOver since no title is shown.
    static func iconCapsule(
        systemImage: String,
        accessibilityLabel: String,
        height: CGFloat = 48,
        action: @escaping () -> Void
    ) -> UIView {
        let button = makeActionButton(systemImage: systemImage, action: action)
        button.accessibilityLabel = accessibilityLabel
        let capsule = capsule(hosting: button, height: height)
        capsule.widthAnchor.constraint(equalToConstant: height + 10).isActive = true
        return capsule
    }

    private static func makeActionButton(systemImage: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: systemImage,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        )
        config.baseForegroundColor = .white
        let button = UIButton(configuration: config)
        button.addAction(UIAction { _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        }, for: .touchUpInside)
        return button
    }
}

/// A glass capsule hosting a control, with an animatable active-state fill
/// and an optional count badge pinned to the top-trailing corner.
final class GlassCapsule: UIView {

    private let activeOverlay = UIView()
    private let badgeLabel = UILabel()
    private let badgeBackground = UIView()

    init(hosting control: UIView, height: CGFloat = 44) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let background: UIView
        if UIAccessibility.isReduceTransparencyEnabled {
            let solid = UIView()
            solid.backgroundColor = UIColor.white.withAlphaComponent(0.16)
            solid.layer.cornerRadius = height / 2
            solid.layer.cornerCurve = .continuous
            solid.clipsToBounds = true
            background = solid
        } else {
            background = LiquidGlass.view(cornerRadius: height / 2, interactive: true)
        }
        background.translatesAutoresizingMaskIntoConstraints = false

        activeOverlay.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        activeOverlay.layer.cornerRadius = height / 2
        activeOverlay.layer.cornerCurve = .continuous
        activeOverlay.alpha = 0
        activeOverlay.isUserInteractionEnabled = false
        activeOverlay.translatesAutoresizingMaskIntoConstraints = false

        control.translatesAutoresizingMaskIntoConstraints = false

        badgeBackground.backgroundColor = .white
        badgeBackground.layer.cornerRadius = 8
        badgeBackground.layer.cornerCurve = .continuous
        badgeBackground.isHidden = true
        badgeBackground.isUserInteractionEnabled = false
        badgeBackground.translatesAutoresizingMaskIntoConstraints = false

        badgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .black
        badgeLabel.textAlignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(background)
        addSubview(activeOverlay)
        addSubview(control)
        badgeBackground.addSubview(badgeLabel)
        addSubview(badgeBackground)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            activeOverlay.topAnchor.constraint(equalTo: topAnchor),
            activeOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            activeOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            activeOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
            badgeBackground.topAnchor.constraint(equalTo: topAnchor, constant: -3),
            badgeBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 3),
            badgeBackground.heightAnchor.constraint(equalToConstant: 16),
            badgeBackground.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeBackground.leadingAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeBackground.trailingAnchor, constant: -5),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeBackground.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setActive(_ active: Bool, animated: Bool = true) {
        let update = { self.activeOverlay.alpha = active ? 1 : 0 }
        if animated {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: update)
        } else {
            update()
        }
    }

    func setBadge(_ text: String?) {
        badgeLabel.text = text
        badgeBackground.isHidden = (text ?? "").isEmpty
    }
}
