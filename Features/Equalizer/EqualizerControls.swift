import FlaccyCore
import UIKit

extension UIFont {

    /// The equalizer's number and title face: the system's rounded design at a Dynamic Type scaled size.
    static func equalizerRounded(_ style: UIFont.TextStyle, size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont(descriptor: descriptor, size: size))
    }
}

/// A small pill with a tinted fill when active: the Auto chip, the type chips
/// of Advanced mode.
final class EqualizerChip: UIControl {

    private let label = UILabel()
    private var tint = EqualizerTheme.fallbackAccent
    private var active = false

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        label.font = .scaled(.footnote, size: 12.5, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.text = title
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        isAccessibilityElement = true
        accessibilityTraits = .button
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }

    func set(title: String, active: Bool, tint: UIColor) {
        label.text = title
        self.active = active
        self.tint = tint
        accessibilityLabel = title
        accessibilityTraits = active ? [.button, .selected] : .button
        applyStyle()
    }

    private func applyStyle() {
        backgroundColor = active ? tint.withAlphaComponent(0.24) : UIColor.white.withAlphaComponent(0.08)
        layer.borderColor = (active ? tint.withAlphaComponent(0.7) : UIColor.white.withAlphaComponent(0.14)).cgColor
        label.textColor = active ? .white : UIColor.white.withAlphaComponent(0.8)
    }
}

/// A preset as a card: its curve drawn small above its name.
final class EqualizerPresetCard: UIControl {

    private let curveLayer = CAShapeLayer()
    private let nameLabel = UILabel()
    private var points: [Double] = []
    private var tint = EqualizerTheme.fallbackAccent
    private var current = false
    private var held = false

    static let size = CGSize(width: 92, height: 84)
    private static let liftScale: CGFloat = 1.06

    /// Runs when VoiceOver's Preview action is chosen, since a screen reader cannot hold and slide.
    var onPreviewRequested: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5

        curveLayer.fillColor = nil
        curveLayer.lineWidth = 2
        curveLayer.lineCap = .round
        curveLayer.lineJoin = .round
        layer.addSublayer(curveLayer)

        nameLabel.font = .scaled(.caption1, size: 12, weight: .semibold, maxSize: 15)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.8
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.size.height),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            nameLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 40),
        ])
        isAccessibilityElement = true
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Preview")) { [weak self] _ in
                self?.onPreviewRequested?()
                return true
            },
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }

    /// Lifts the card while a finger holds it and its preset is playing, with a brighter ring.
    /// Reduce Motion keeps the ring and drops the pop.
    func setHeld(_ isHeld: Bool, animated: Bool) {
        guard held != isHeld else { return }
        held = isHeld
        let scale: CGFloat = isHeld && !UIAccessibility.isReduceMotionEnabled ? Self.liftScale : 1
        let changes = {
            self.applyStyle()
            self.transform = CGAffineTransform(scaleX: scale, y: scale)
            self.layer.shadowOpacity = isHeld ? 0.45 : 0
        }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.18, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
    }

    func configure(name: String, points: [Double], isCurrent: Bool, tint: UIColor) {
        nameLabel.text = name
        self.points = points
        current = isCurrent
        self.tint = tint
        accessibilityLabel = name
        accessibilityTraits = isCurrent ? [.button, .selected] : .button
        applyStyle()
        setNeedsLayout()
    }

    private func applyStyle() {
        let lit = current || held
        backgroundColor = held ? tint.withAlphaComponent(0.34) : (current ? tint.withAlphaComponent(0.2) : UIColor.white.withAlphaComponent(0.06))
        layer.borderColor = (held ? UIColor.white : (current ? tint : UIColor.white.withAlphaComponent(0.10))).cgColor
        layer.borderWidth = held ? 2 : 1.5
        layer.shadowColor = tint.cgColor
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 4)
        curveLayer.strokeColor = (lit ? (held ? UIColor.white : tint) : UIColor.white.withAlphaComponent(0.62)).cgColor
        nameLabel.textColor = lit ? .white : UIColor.white.withAlphaComponent(0.74)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = CGRect(x: 14, y: 14, width: bounds.width - 28, height: 26)
        let path = UIBezierPath()
        for (index, decibels) in points.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(points.count - 1)
            let clamped = min(max(decibels, -9), 9)
            let y = rect.midY - CGFloat(clamped / 9) * rect.height / 2
            index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        curveLayer.path = path.cgPath
        curveLayer.frame = bounds
    }
}

/// The "Hearing Rock" capsule on the curve card while a preset is being
/// auditioned, which turns into "Release to cancel" once the finger has
/// slid away from the strip.
final class EqualizerHearingPill: UIView {

    private let icon = UIImageView()
    private let label = UILabel()
    private var shown: (name: String, cancelling: Bool)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        alpha = 0
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = UIColor.black.withAlphaComponent(0.55)
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.font = .scaled(.caption1, size: 12, weight: .semibold, maxSize: 16)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.spacing = 6
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    /// Shows the capsule for `name`, or hides it when `name` is nil.
    func set(name: String?, cancelling: Bool, accent: UIColor) {
        guard let name else {
            shown = nil
            fade(to: 0)
            return
        }
        guard shown?.name != name || shown?.cancelling != cancelling else { return }
        shown = (name, cancelling)
        let apply = {
            self.label.text = cancelling ? String(localized: "Release to cancel") : String(localized: "Hearing \(name)")
            let symbol = cancelling ? "xmark.circle.fill" : "waveform"
            self.icon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
            self.icon.tintColor = cancelling ? EqualizerTheme.caution : accent
            self.layer.borderColor = (cancelling ? EqualizerTheme.caution : accent).withAlphaComponent(0.7).cgColor
        }
        if alpha > 0, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: self, duration: 0.16, options: [.transitionCrossDissolve, .allowUserInteraction], animations: apply)
        } else {
            apply()
        }
        fade(to: 1)
    }

    private func fade(to target: CGFloat) {
        guard alpha != target else { return }
        if UIAccessibility.isReduceMotionEnabled {
            alpha = target
        } else {
            UIView.animate(withDuration: 0.16, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.alpha = target }
        }
    }
}

/// The one place an audition starts and ends on the phone. It publishes the
/// previewed profile to the engine without saving it, and puts back what was
/// playing whenever it ends, including when the app resigns active.
@MainActor
final class EqualizerAuditioner: NSObject {

    private let engine = EqualizerEngine.shared
    private(set) var current: EqualizerProfile?

    /// Runs after every start, switch and end, with the profile now being heard or nil.
    var didChange: ((EqualizerProfile?) -> Void)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(appResigned), name: UIApplication.willResignActiveNotification, object: nil)
    }

    func begin(_ profile: EqualizerProfile) {
        guard current?.id != profile.id else { return }
        current = profile
        engine.beginAudition(profile)
        didChange?(profile)
    }

    func end() {
        guard current != nil else { return }
        current = nil
        engine.endAudition()
        didChange?(nil)
    }

    @objc private func appResigned() {
        end()
    }
}

/// A horizontal ruler you scrub the way you turn the Camera's exposure dial:
/// the marks slide under a fixed pointer, and one light tick lands for every
/// mark that passes it.
final class EqualizerRulerView: UIControl {

    var onScrub: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?

    private let ticksLayer = CAShapeLayer()
    private let pointer = UIView()
    private var startX: CGFloat = 0
    private var offset: CGFloat = 0
    private var lastTickIndex = 0
    private let haptic = UISelectionFeedbackGenerator()
    private static let spacing: CGFloat = 8

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        backgroundColor = UIColor.white.withAlphaComponent(0.05)
        ticksLayer.strokeColor = UIColor.white.withAlphaComponent(0.34).cgColor
        ticksLayer.lineWidth = 1
        layer.addSublayer(ticksLayer)
        pointer.translatesAutoresizingMaskIntoConstraints = false
        pointer.layer.cornerRadius = 1
        addSubview(pointer)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            pointer.centerXAnchor.constraint(equalTo: centerXAnchor),
            pointer.topAnchor.constraint(equalTo: topAnchor),
            pointer.bottomAnchor.constraint(equalTo: bottomAnchor),
            pointer.widthAnchor.constraint(equalToConstant: 2),
        ])
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var pointerColor: UIColor = EqualizerTheme.fallbackAccent {
        didSet { pointer.backgroundColor = pointerColor }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        redrawTicks()
    }

    private func redrawTicks() {
        let path = UIBezierPath()
        let shift = offset.truncatingRemainder(dividingBy: Self.spacing)
        var x = shift - Self.spacing
        var index = 0
        while x < bounds.width + Self.spacing {
            let major = index % 5 == 0
            path.move(to: CGPoint(x: x, y: bounds.height))
            path.addLine(to: CGPoint(x: x, y: bounds.height - (major ? 14 : 8)))
            x += Self.spacing
            index += 1
        }
        ticksLayer.path = path.cgPath
        ticksLayer.frame = bounds
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let dx = gesture.translation(in: self).x
        switch gesture.state {
        case .began:
            haptic.prepare()
            lastTickIndex = Int((dx / Self.spacing).rounded(.towardZero))
        case .changed:
            offset = dx
            let tick = Int((dx / Self.spacing).rounded(.towardZero))
            if tick != lastTickIndex {
                haptic.selectionChanged()
                lastTickIndex = tick
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            redrawTicks()
            CATransaction.commit()
            onScrub?(dx)
        case .ended, .cancelled, .failed:
            offset = 0
            redrawTicks()
            onEnd?()
        default:
            break
        }
    }

    override func accessibilityIncrement() { onScrub?(Self.spacing * 2); onEnd?() }
    override func accessibilityDecrement() { onScrub?(-Self.spacing * 2); onEnd?() }
}

/// A thin level bar: how loud the equalizer's output is right now.
final class EqualizerMeterBar: UIView {

    private let fill = UIView()
    private var fraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = UIColor.white.withAlphaComponent(0.1)
        layer.cornerRadius = 3
        layer.masksToBounds = true
        addSubview(fill)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 6),
            widthAnchor.constraint(equalToConstant: 56),
        ])
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(peakDecibels: Float, color: UIColor) {
        fraction = CGFloat(min(max((peakDecibels + 30) / 30, 0), 1))
        fill.backgroundColor = color
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
    }
}

/// The small "EQ" mark beside the quality badge on Now Playing, shown while the
/// equalizer is shaping the sound, so the lossless badge never overstates what
/// is reaching the output. Tapping it opens the equalizer.
final class EqualizerBadgeView: UIControl {

    var accent: UIColor = EqualizerTheme.fallbackAccent {
        didSet { applyTint() }
    }

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        label.text = "EQ"
        label.font = .scaled(.caption2, size: 11, weight: .heavy)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isUserInteractionEnabled = false
        addSubview(label)
        layer.cornerRadius = 10
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = String(localized: "Equalizer is on")
        isHidden = true
        applyTint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    private func applyTint() {
        backgroundColor = accent.withAlphaComponent(0.22)
        layer.borderColor = accent.withAlphaComponent(0.7).cgColor
        label.textColor = .white
    }
}
