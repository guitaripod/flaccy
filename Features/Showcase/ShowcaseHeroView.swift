import UIKit

/// The top of the showcase: the app's icon over a soft glow, its name, the version in large numerals filled with the
/// accent, and one line under them. Each part arrives by itself when the entrance plays.
final class ShowcaseHeroView: UIView {

    private let glow = ShowcaseGlowView()
    private let icon = UIImageView()
    private let nameLabel = UILabel()
    private let versionView = ShowcaseVersionView(text: ShowcaseCopy.version)
    private let taglineLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        let image = WelcomeViewController.appIcon()
        icon.image = image ?? UIImage(systemName: "music.note")
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .tintColor
        icon.layer.cornerRadius = 16
        icon.layer.cornerCurve = .continuous
        icon.clipsToBounds = image != nil
        icon.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.text = ShowcaseCopy.name
        nameLabel.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 22, weight: .semibold))
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label
        nameLabel.textAlignment = .center

        taglineLabel.text = ShowcaseCopy.tagline
        taglineLabel.font = .preferredFont(forTextStyle: .subheadline)
        taglineLabel.adjustsFontForContentSizeCategory = true
        taglineLabel.textColor = .secondaryLabel
        taglineLabel.textAlignment = .center
        taglineLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, nameLabel, versionView, taglineLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(-6, after: nameLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        glow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glow)
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 68),
            icon.heightAnchor.constraint(equalToConstant: 68),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            glow.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            glow.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            glow.widthAnchor.constraint(equalToConstant: 260),
            glow.heightAnchor.constraint(equalToConstant: 260),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .header
        accessibilityLabel = "\(ShowcaseCopy.name) \(ShowcaseCopy.version). \(ShowcaseCopy.tagline)"
    }

    /// Hides every part, ready for ``playEntrance(gentle:)``.
    func prepareForEntrance() {
        [glow, icon, nameLabel, versionView, taglineLabel].forEach { $0.alpha = 0 }
        glow.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        icon.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
        nameLabel.transform = CGAffineTransform(translationX: 0, y: 10)
        versionView.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        taglineLabel.transform = CGAffineTransform(translationX: 0, y: 10)
    }

    /// Brings the parts in on the showcase's clock. With `gentle` they fade in together and nothing moves.
    func playEntrance(gentle: Bool) {
        guard !gentle else {
            [glow, icon, nameLabel, versionView, taglineLabel].forEach { $0.transform = .identity }
            UIView.animate(withDuration: 0.3) {
                [self.glow, self.icon, self.nameLabel, self.versionView, self.taglineLabel].forEach { $0.alpha = 1 }
            }
            return
        }
        UIView.animate(withDuration: 0.7, delay: ShowcaseTiming.icon, options: .curveEaseOut) {
            self.glow.alpha = 1
            self.glow.transform = .identity
        }
        Self.spring(delay: ShowcaseTiming.icon) {
            self.icon.alpha = 1
            self.icon.transform = .identity
        }
        Self.rise(nameLabel, delay: ShowcaseTiming.name)
        Self.spring(delay: ShowcaseTiming.version) {
            self.versionView.alpha = 1
            self.versionView.transform = .identity
        }
        versionView.shine(after: ShowcaseTiming.versionLands)
        Self.rise(taglineLabel, delay: ShowcaseTiming.tagline)
    }

    /// Fades a view in while it rises the last few points into place.
    static func rise(_ view: UIView, delay: TimeInterval) {
        UIView.animate(withDuration: ShowcaseTiming.settle, delay: delay, options: .curveEaseOut) {
            view.alpha = 1
            view.transform = .identity
        }
    }

    private static func spring(delay: TimeInterval, _ changes: @escaping () -> Void) {
        UIView.animate(
            withDuration: 0.55, delay: delay, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.4,
            options: .curveEaseOut, animations: changes
        )
    }
}

/// The version in large rounded numerals, filled with a gradient of the accent, with one pass of light across it.
final class ShowcaseVersionView: UIView {

    private let gradient = CAGradientLayer()
    private let light = CAGradientLayer()
    private let fill = UIView()
    private let numerals = UILabel()

    init(text: String) {
        super.init(frame: .zero)
        numerals.text = text
        numerals.font = Self.font
        numerals.textAlignment = .center
        numerals.adjustsFontSizeToFitWidth = true
        numerals.minimumScaleFactor = 0.6

        gradient.startPoint = CGPoint(x: 0, y: 0.2)
        gradient.endPoint = CGPoint(x: 1, y: 0.8)
        light.startPoint = CGPoint(x: 0, y: 0.5)
        light.endPoint = CGPoint(x: 1, y: 0.5)
        light.colors = [UIColor.white.withAlphaComponent(0).cgColor, UIColor.white.withAlphaComponent(0.75).cgColor, UIColor.white.withAlphaComponent(0).cgColor]
        light.opacity = 0
        fill.layer.addSublayer(gradient)
        fill.layer.addSublayer(light)
        fill.mask = numerals
        addSubview(fill)
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ShowcaseVersionView, _) in view.applyColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static var font: UIFont {
        let base = UIFont.systemFont(ofSize: 88, weight: .heavy)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: rounded, size: 88)
    }

    override var intrinsicContentSize: CGSize {
        let size = numerals.intrinsicContentSize
        return CGSize(width: size.width + 8, height: size.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fill.frame = bounds
        numerals.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        light.frame = CGRect(x: -bounds.width, y: 0, width: bounds.width * 0.6, height: bounds.height)
        CATransaction.commit()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }

    /// The accent and a neighbour of it a little round the colour wheel, so the numerals read as lit rather than flat.
    private func applyColors() {
        let accent = tintColor.resolvedColor(with: traitCollection)
        gradient.colors = [accent.cgColor, Self.neighbour(of: accent).cgColor]
    }

    private static func neighbour(of color: UIColor) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return color }
        guard saturation > 0.08 else {
            return UIColor(hue: hue, saturation: saturation, brightness: min(brightness + 0.25, 1), alpha: alpha)
        }
        let turned = (hue + 0.11).truncatingRemainder(dividingBy: 1)
        return UIColor(hue: turned, saturation: max(saturation * 0.85, 0.35), brightness: min(brightness * 1.12, 1), alpha: alpha)
    }

    /// Sends one band of light across the numerals, left to right, and leaves nothing behind.
    func shine(after delay: TimeInterval) {
        layoutIfNeeded()
        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = -bounds.width * 0.3
        travel.toValue = bounds.width * 1.3
        let show = CAKeyframeAnimation(keyPath: "opacity")
        show.values = [0, 1, 1, 0]
        show.keyTimes = [0, 0.15, 0.85, 1]
        let pass = CAAnimationGroup()
        pass.animations = [travel, show]
        pass.duration = 0.65
        pass.beginTime = CACurrentMediaTime() + delay
        pass.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        light.add(pass, forKey: "shine")
    }
}

/// A round wash of the accent that fades to nothing at its edge, behind the icon.
final class ShowcaseGlowView: UIView {

    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.type = .radial
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ShowcaseGlowView, _) in view.applyColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyColors()
    }

    private func applyColors() {
        guard let gradient = layer as? CAGradientLayer else { return }
        let accent = tintColor.resolvedColor(with: traitCollection)
        let strength: CGFloat = traitCollection.userInterfaceStyle == .dark ? 0.42 : 0.26
        gradient.colors = [accent.withAlphaComponent(strength).cgColor, accent.withAlphaComponent(0).cgColor]
    }
}
