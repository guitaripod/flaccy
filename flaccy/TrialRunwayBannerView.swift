import UIKit

/// The day-6 runway, as a line the Library can carry without taking anything
/// away: under a day of trial is left, here is the one button that matters, and a
/// close that puts it away for good. Never a sheet — nothing here is modal.
final class TrialRunwayBannerView: UIView {

    var onGetLifetime: (() -> Void)?
    var onDismiss: (() -> Void)?

    private static let accent = QualityBadgeView.losslessTint

    private let card = UIView()
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactLight = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "library.runwayBanner"
        buildCard()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildCard() {
        card.backgroundColor = Self.accent.withAlphaComponent(
            UIAccessibility.isReduceTransparencyEnabled ? 0.22 : 0.14
        )
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = Self.accent.withAlphaComponent(0.4).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let symbolView = UIImageView(
            image: UIImage(
                systemName: "hourglass",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            )
        )
        symbolView.tintColor = Self.accent
        symbolView.contentMode = .center
        symbolView.setContentHuggingPriority(.required, for: .horizontal)
        symbolView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleLabel = UILabel()
        titleLabel.text = PaywallCopy.lastDayLine
        titleLabel.font = .scaled(.subheadline, size: 15, weight: .semibold, maxSize: 22)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2

        let row = UIStackView(arrangedSubviews: [symbolView, titleLabel, makeLifetimeButton(), makeCloseButton()])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: card.topAnchor),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }

    private func makeLifetimeButton() -> UIButton {
        var config = UIButton.Configuration.filled()
        config.attributedTitle = AttributedString(
            String(localized: "Get Lifetime"),
            attributes: AttributeContainer([.font: UIFont.scaled(.footnote, size: 13, weight: .bold, maxSize: 18)])
        )
        config.baseBackgroundColor = Self.accent
        config.baseForegroundColor = .black
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = "library.runwayBanner.getLifetime"
        button.accessibilityHint = String(localized: "Shows the one-time purchase that unlocks flaccy forever")
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addAction(UIAction { [weak self] _ in
            self?.impactMedium.impactOccurred()
            self?.onGetLifetime?()
        }, for: .touchUpInside)
        return button
    }

    private func makeCloseButton() -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        )
        config.baseForegroundColor = .secondaryLabel
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8)
        let button = UIButton(configuration: config)
        button.accessibilityLabel = String(localized: "Dismiss")
        button.accessibilityIdentifier = "library.runwayBanner.dismiss"
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addAction(UIAction { [weak self] _ in
            self?.impactLight.impactOccurred()
            self?.onDismiss?()
        }, for: .touchUpInside)
        return button
    }

    /// The height the banner needs at the given width, so the Library can
    /// animate its slot open and closed without guessing at Dynamic Type. The
    /// card is measured rather than the banner because the Library pins the
    /// banner's own height, which would otherwise answer with the slot's size.
    func expandedHeight(forWidth width: CGFloat) -> CGFloat {
        let cardHeight = card.systemLayoutSizeFitting(
            CGSize(width: max(0, width - 32), height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        return cardHeight + 12
    }
}
