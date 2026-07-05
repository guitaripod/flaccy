import UIKit

/// flaccy's audiophile signature: a compact pill spelling out a track's codec
/// and bit-depth / sample-rate (e.g. "FLAC · 24/96"). Lossless formats get a
/// subtle cyan accent tint; the pill hides itself when quality is unknown.
final class QualityBadgeView: UIView {

    enum Size {
        case regular
        case compact
    }

    static let losslessTint = UIColor(red: 0.45, green: 0.86, blue: 0.92, alpha: 1)

    private static let losslessDynamicTint = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? losslessTint
            : UIColor(red: 0.0, green: 0.42, blue: 0.5, alpha: 1)
    }
    private static let lossyDynamicTint = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.6)
            : UIColor.black.withAlphaComponent(0.55)
    }

    private let label = UILabel()
    private var showsLossless = false

    init(size: Size = .regular) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        let fontSize: CGFloat = size == .regular ? 11 : 9.5
        label.font = .scaled(.caption2, size: fontSize, weight: .heavy)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let height: CGFloat = size == .regular ? 20 : 17
        let pad: CGFloat = size == .regular ? 8 : 6
        layer.cornerRadius = height / 2
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: height),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .staticText

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: QualityBadgeView, _) in
            self.applyTint()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with track: Track?) {
        guard let badge = track?.qualityBadge, let track else {
            isHidden = true
            label.text = nil
            accessibilityLabel = nil
            return
        }
        isHidden = false
        label.text = badge.uppercased()
        showsLossless = track.isLossless
        applyTint()

        let spoken = badge.replacingOccurrences(of: "·", with: "")
        accessibilityLabel = (showsLossless ? "Lossless, " : "Quality, ") + spoken
    }

    private func applyTint() {
        let tint = showsLossless ? Self.losslessDynamicTint : Self.lossyDynamicTint
        let resolved = tint.resolvedColor(with: traitCollection)
        label.textColor = resolved
        layer.borderColor = resolved.withAlphaComponent(showsLossless ? 0.5 : 0.25).cgColor
        backgroundColor = resolved.withAlphaComponent(showsLossless ? 0.14 : 0.06)
    }
}
