import UIKit

enum HomePromoAction {
    case addMusic
    case playSample
    case computerGuide
    case seePlans
    case getLifetime
    case restorePurchases
}

/// The glass surface Home's promo cards share: a rounded card with the hero's
/// hairline border and a vertical stack of its content.
class HomePromoCardCell: UICollectionViewCell {

    var onAction: ((HomePromoAction) -> Void)?

    let content = UIStackView()
    static let buttonHeight: CGFloat = 48

    private let glass = LiquidGlass.view(cornerRadius: 28)

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(glass)
        content.axis = .vertical
        content.spacing = 10
        content.alignment = .fill
        content.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(content)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: contentView.topAnchor),
            glass.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            content.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])
        applyBorder()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: HomePromoCardCell, _) in cell.applyBorder() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyBorder() {
        glass.layer.borderWidth = 1
        glass.layer.borderColor = UIColor.label.withAlphaComponent(0.14).resolvedColor(with: traitCollection).cgColor
    }

    func resetContent() {
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
    }

    func label(_ text: String, style: UIFont.TextStyle, size: CGFloat, weight: UIFont.Weight, maxSize: CGFloat? = nil, color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = maxSize.map { .scaled(style, size: size, weight: weight, maxSize: $0) } ?? .scaled(style, size: size, weight: weight)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    func primaryButton(title: String, symbol: String?, action: HomePromoAction) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.imagePadding = 8
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .label
        configuration.baseForegroundColor = .systemBackground
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.scaled(.body, size: 17, weight: .semibold, maxSize: 22)
            attributes.foregroundColor = UIColor.systemBackground
            return attributes
        }
        return button(configuration: configuration, title: title, action: action)
    }

    func secondaryButton(title: String, subtitle: String? = nil, symbol: String? = nil, showsActivity: Bool = false, action: HomePromoAction) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.subtitle = subtitle
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.imagePadding = 8
        configuration.showsActivityIndicator = showsActivity
        configuration.baseForegroundColor = .label
        configuration.titleAlignment = .center
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18)
        configuration.background.backgroundColor = UIColor.label.withAlphaComponent(0.12)
        configuration.background.cornerRadius = Self.buttonHeight / 2
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.scaled(.body, size: 17, weight: .semibold, maxSize: 22)
            return attributes
        }
        configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.scaled(.caption1, size: 12, weight: .regular, maxSize: 16)
            attributes.foregroundColor = UIColor.secondaryLabel
            return attributes
        }
        return button(configuration: configuration, title: title, action: action)
    }

    func linkButton(title: String, symbol: String?, action: HomePromoAction) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.imagePadding = 6
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.scaled(.subheadline, size: 15, weight: .semibold, maxSize: 21)
            return attributes
        }
        return button(configuration: configuration, title: title, action: action)
    }

    private func button(configuration: UIButton.Configuration, title: String, action: HomePromoAction) -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = configuration
        button.accessibilityLabel = title
        button.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.onAction?(action)
        }, for: .touchUpInside)
        if configuration.background.cornerRadius > 0 || configuration.cornerStyle == .capsule {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonHeight).isActive = true
        }
        return button
    }
}

/// Home's invitation to bring music in, for a library with nothing of the
/// person's own: the Library's empty-state actions behind a card.
final class HomeGetStartedCell: HomePromoCardCell {

    static let reuseID = "HomeGetStartedCell"

    func configure(with content: HomeGetStartedContent, sample: HomeSampleButton) {
        resetContent()
        let title = label(content.title, style: .title2, size: 26, weight: .heavy, maxSize: 34)
        title.accessibilityTraits = .header
        self.content.addArrangedSubview(title)
        self.content.addArrangedSubview(label(content.body, style: .subheadline, size: 15, weight: .regular, color: .secondaryLabel))
        self.content.setCustomSpacing(18, after: self.content.arrangedSubviews.last ?? title)
        self.content.addArrangedSubview(primaryButton(title: HomeCopy.addMusic, symbol: "plus", action: .addMusic))
        let sampleButton = secondaryButton(
            title: sample.title, subtitle: sample.subtitle, symbol: sample.isDownloading ? nil : "play.circle",
            showsActivity: sample.isDownloading, action: .playSample
        )
        sampleButton.isEnabled = !sample.isDownloading
        self.content.addArrangedSubview(sampleButton)
        let guide = linkButton(title: HomeCopy.otherWaysToAdd, symbol: "laptopcomputer.and.iphone", action: .computerGuide)
        self.content.addArrangedSubview(guide)
        if let footnote = content.footnote {
            self.content.addArrangedSubview(label(footnote, style: .footnote, size: 13, weight: .regular, color: .secondaryLabel))
        }
    }
}

/// A card that sells Flaccy Pro: what the person has set up, the Lifetime
/// price, and a way to the paywall. It never buys by itself.
final class HomePlanCardCell: HomePromoCardCell {

    static let reuseID = "HomePlanCardCell"

    func configure(with plan: HomePlanCardContent) {
        resetContent()
        content.addArrangedSubview(label(plan.kicker, style: .footnote, size: 13, weight: .semibold, color: .secondaryLabel))
        let title = label(plan.title, style: .title2, size: 26, weight: .heavy, maxSize: 34)
        title.accessibilityTraits = .header
        content.addArrangedSubview(title)
        for line in plan.proofLines {
            content.addArrangedSubview(proofRow(line))
        }
        content.setCustomSpacing(18, after: content.arrangedSubviews.last ?? title)
        content.addArrangedSubview(primaryButton(title: plan.primaryTitle, symbol: nil, action: .getLifetime))
        if let caption = plan.caption {
            let captionLabel = label(caption, style: .footnote, size: 13, weight: .regular, color: .secondaryLabel)
            captionLabel.textAlignment = .center
            content.addArrangedSubview(captionLabel)
        }
        content.addArrangedSubview(secondaryButton(title: HomeCopy.seePlans, action: .seePlans))
        if plan.offersRestore {
            content.addArrangedSubview(linkButton(title: HomeCopy.restorePurchases, symbol: nil, action: .restorePurchases))
        }
    }

    private func proofRow(_ text: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        icon.tintColor = .tintColor
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        let line = label(text, style: .subheadline, size: 15, weight: .regular)
        let row = UIStackView(arrangedSubviews: [icon, line])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .firstBaseline
        return row
    }
}

/// One quiet line under the hero, for a trial that waits on the first song.
final class HomePromoNoteCell: UICollectionViewCell {

    static let reuseID = "HomePromoNoteCell"

    private let noteLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        noteLabel.font = .scaled(.footnote, size: 13, weight: .regular)
        noteLabel.adjustsFontForContentSizeCategory = true
        noteLabel.textColor = .secondaryLabel
        noteLabel.numberOfLines = 0
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(noteLabel)
        NSLayoutConstraint.activate([
            noteLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            noteLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            noteLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            noteLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String) {
        noteLabel.text = text
    }
}
