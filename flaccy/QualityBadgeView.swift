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
    private static let lossyTint = UIColor.white.withAlphaComponent(0.6)

    private let label = UILabel()

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

        let lossless = track.isLossless
        let tint = lossless ? Self.losslessTint : Self.lossyTint
        label.textColor = tint
        layer.borderColor = tint.withAlphaComponent(lossless ? 0.5 : 0.25).cgColor
        backgroundColor = tint.withAlphaComponent(lossless ? 0.14 : 0.06)

        let spoken = badge.replacingOccurrences(of: "·", with: "")
        accessibilityLabel = (lossless ? "Lossless, " : "Quality, ") + spoken
    }
}
