import UIKit

/// A heart toggle for a track's loved state — a hollow heart when not loved, a
/// filled rose heart with a spring "pop" when loved. Loved is its own signal
/// and is never conflated with playlist membership.
final class LoveButton: UIButton {

    static let lovedTint = UIColor(red: 1.0, green: 0.28, blue: 0.42, alpha: 1)
    private static let restTint = UIColor.white.withAlphaComponent(0.82)

    private(set) var isLoved = false
    private let pointSize: CGFloat

    /// Invoked on tap; the caller performs the toggle and reconciles state.
    var onToggle: (() -> Void)?

    init(pointSize: CGFloat = 22) {
        self.pointSize = pointSize
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        accessibilityLabel = "Love"
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)
        apply(loved: false, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setLoved(_ loved: Bool, animated: Bool) {
        let changed = loved != isLoved
        apply(loved: loved, animated: animated && changed)
    }

    private func apply(loved: Bool, animated: Bool) {
        isLoved = loved
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        let image = UIImage(systemName: loved ? "heart.fill" : "heart", withConfiguration: config)
        tintColor = loved ? Self.lovedTint : Self.restTint
        setImage(image, for: .normal)
        accessibilityValue = loved ? "Loved" : "Not loved"
        guard animated else { return }
        pop(loved: loved)
    }

    /// Springs the glyph up and back — an emphatic bloom when loving, a gentle
    /// dip when unloving — paired with a matching haptic. Skipped under Reduce
    /// Motion (the haptic still fires).
    private func pop(loved: Bool) {
        UIImpactFeedbackGenerator(style: loved ? .rigid : .light).impactOccurred()
        guard !UIAccessibility.isReduceMotionEnabled, let target = imageView else { return }
        let peak: CGFloat = loved ? 1.34 : 0.84
        let up = UIViewPropertyAnimator(duration: 0.12, dampingRatio: 0.5) {
            target.transform = CGAffineTransform(scaleX: peak, y: peak)
        }
        up.addCompletion { _ in
            let down = UIViewPropertyAnimator(duration: 0.22, dampingRatio: 0.55) {
                target.transform = .identity
            }
            down.startAnimation()
        }
        up.startAnimation()
    }
}
