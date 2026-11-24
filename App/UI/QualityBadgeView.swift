import FlaccyCore
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

    static let losslessDynamicTint = UIColor { traits in
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
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.78
        label.lineBreakMode = .byClipping
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

        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeEpochTrait.self]) { (self: QualityBadgeView, _) in
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
        accessibilityLabel = (showsLossless ? String(localized: "Lossless, ") : String(localized: "Quality, ")) + spoken
    }

    private func applyTint() {
        let tint = showsLossless ? Self.losslessDynamicTint : Self.lossyDynamicTint
        let resolved = tint.resolvedColor(with: traitCollection)
        label.textColor = resolved
        layer.borderColor = resolved.withAlphaComponent(showsLossless ? 0.5 : 0.25).cgColor
        backgroundColor = resolved.withAlphaComponent(showsLossless ? 0.14 : 0.06)
    }
}

/// The marks a library row puts after its title — the New mix chip, the
/// downloaded mark, the play count, the loved heart and the quality pill — made
/// of plain labels and images laid out by hand. Building a stack of constraints
/// and a quality badge with its own trait registrations for every dequeued row
/// put a layout solve on the scroll path of every list.
final class ListBadgeRow: UIView {

    struct Marks {
        var newMix = false
        var downloaded = false
        var scrobbleCount: Int?
        var loved = false
        var quality: Track?
    }

    private static let spacing: CGFloat = 6

    private let parts: [UIView]

    init(marks: Marks, traits: UITraitCollection) {
        var parts: [UIView] = []
        if marks.newMix {
            parts.append(BadgePill(
                text: TrackVersionCopy.newMix.uppercased(),
                tint: QualityBadgeView.losslessDynamicTint,
                traits: traits
            ))
        }
        if marks.downloaded {
            let mark = UIImageView(image: UIImage(
                systemName: "arrow.down.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            ))
            mark.tintColor = QualityBadgeView.losslessDynamicTint.resolvedColor(with: traits)
            mark.contentMode = .center
            mark.isAccessibilityElement = false
            parts.append(mark)
        }
        if let count = marks.scrobbleCount {
            parts.append(ScrobbleMark(count: count, traits: traits))
        }
        if marks.loved {
            let heart = UIImageView(image: UIImage(
                systemName: "heart.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            ))
            heart.tintColor = .systemPink
            heart.contentMode = .center
            heart.accessibilityLabel = String(localized: "Loved")
            heart.isAccessibilityElement = true
            parts.append(heart)
        }
        if let quality = marks.quality, let badge = quality.qualityBadge {
            let pill = BadgePill(
                text: badge.uppercased(),
                tint: quality.isLossless ? QualityBadgeView.losslessDynamicTint : BadgePill.lossyTint,
                traits: traits
            )
            let spoken = badge.replacingOccurrences(of: "·", with: "")
            pill.accessibilityLabel = (quality.isLossless ? String(localized: "Lossless, ") : String(localized: "Quality, ")) + spoken
            pill.isAccessibilityElement = true
            parts.append(pill)
        }
        self.parts = parts
        super.init(frame: .zero)
        parts.forEach(addSubview)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let widths = parts.map { $0.intrinsicContentSize.width }
        let height = parts.map { $0.intrinsicContentSize.height }.max() ?? 17
        let spacing = Self.spacing * CGFloat(max(parts.count - 1, 0))
        return CGSize(width: ceil(widths.reduce(0, +) + spacing), height: ceil(height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        for part in parts {
            let size = part.intrinsicContentSize
            part.frame = CGRect(
                x: x, y: ((bounds.height - size.height) / 2).rounded(.down), width: size.width, height: size.height
            )
            x += size.width + Self.spacing
        }
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        intrinsicContentSize
    }
}

/// A capsule spelling out a short mark in the quality badge's shape: the New mix
/// chip and the codec pill, without the constraints a badge view carries.
private final class BadgePill: UILabel {

    static let lossyTint = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.6)
            : UIColor.black.withAlphaComponent(0.55)
    }

    private let horizontalPadding: CGFloat = 6

    init(text: String, tint: UIColor, traits: UITraitCollection) {
        super.init(frame: .zero)
        self.text = text
        font = .scaled(.caption2, size: 9.5, weight: .heavy)
        adjustsFontForContentSizeCategory = true
        adjustsFontSizeToFitWidth = true
        minimumScaleFactor = 0.78
        lineBreakMode = .byClipping
        textAlignment = .center
        setContentCompressionResistancePriority(.required, for: .horizontal)
        layer.cornerCurve = .continuous
        layer.borderWidth = 1

        let resolved = tint.resolvedColor(with: traits)
        let lossless = resolved != BadgePill.lossyTint.resolvedColor(with: traits)
        textColor = resolved
        layer.borderColor = resolved.withAlphaComponent(lossless ? 0.5 : 0.25).cgColor
        backgroundColor = resolved.withAlphaComponent(lossless ? 0.14 : 0.06)
        layer.cornerRadius = intrinsicContentSize.height / 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let measured = NSAttributedString(string: text ?? "", attributes: [.font: font as Any]).size()
        return CGSize(width: ceil(measured.width) + horizontalPadding * 2, height: max(17, ceil(measured.height)))
    }

    /// Keeps the hand padding outside the text so the label never narrows itself into an
    /// ellipsis to make room for it.
    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let inset = bounds.insetBy(dx: horizontalPadding, dy: 0)
        let rect = super.textRect(forBounds: inset, limitedToNumberOfLines: numberOfLines)
        return rect.insetBy(dx: -horizontalPadding, dy: 0)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.insetBy(dx: horizontalPadding, dy: 0))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

/// The waveform glyph and count a song row shows when its plays are known.
private final class ScrobbleMark: UIView {

    private let glyph = UIImageView(image: UIImage(
        systemName: "waveform",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
    ))
    private let label = UILabel()

    init(count: Int, traits: UITraitCollection) {
        super.init(frame: .zero)
        glyph.tintColor = UIColor.flaccyTertiaryLabel.resolvedColor(with: traits)
        label.text = count > 999 ? String(localized: "\(count / 1000)k") : "\(count)"
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = UIColor.flaccySecondaryLabel.resolvedColor(with: traits)
        addSubview(glyph)
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "\(count) scrobbles")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let glyphSize = glyph.intrinsicContentSize
        let labelSize = label.intrinsicContentSize
        return CGSize(width: ceil(glyphSize.width + 3 + labelSize.width), height: max(glyphSize.height, labelSize.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let glyphSize = glyph.intrinsicContentSize
        let labelSize = label.intrinsicContentSize
        glyph.frame = CGRect(
            x: 0, y: ((bounds.height - glyphSize.height) / 2).rounded(.down), width: glyphSize.width, height: glyphSize.height
        )
        label.frame = CGRect(
            x: glyphSize.width + 3,
            y: ((bounds.height - labelSize.height) / 2).rounded(.down),
            width: labelSize.width,
            height: labelSize.height
        )
    }
}
