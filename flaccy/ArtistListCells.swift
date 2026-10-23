import UIKit

/// A Last.fm popular-track row showing global rank, title, an owned checkmark
/// when the track exists in the local library, and its scrobble count.
final class PopularTrackCell: UICollectionViewCell {

    let rankLabel = UILabel()
    let ownedBadge = UIImageView()
    let titleLabel = UILabel()
    let playCountLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        rankLabel.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 15, weight: .regular), maximumPointSize: 24)
        rankLabel.adjustsFontForContentSizeCategory = true
        rankLabel.textColor = .white.withAlphaComponent(0.45)
        rankLabel.textAlignment = .center
        rankLabel.setContentHuggingPriority(.required, for: .horizontal)

        ownedBadge.image = UIImage(
            systemName: "checkmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        )
        ownedBadge.tintColor = .systemGreen
        ownedBadge.contentMode = .center
        ownedBadge.setContentHuggingPriority(.required, for: .horizontal)
        ownedBadge.isAccessibilityElement = false

        titleLabel.font = .scaled(.body, size: 16, weight: .regular)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        playCountLabel.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .regular), maximumPointSize: 22)
        playCountLabel.adjustsFontForContentSizeCategory = true
        playCountLabel.textColor = .white.withAlphaComponent(0.4)
        playCountLabel.textAlignment = .right
        playCountLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [rankLabel, ownedBadge, titleLabel, playCountLabel])
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            rankLabel.widthAnchor.constraint(equalToConstant: 24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with item: PopularTrackItem) {
        rankLabel.text = item.rank > 0 ? "\(item.rank)" : "\u{2013}"
        titleLabel.text = item.name
        let owned = item.ownedTrack != nil
        ownedBadge.isHidden = !owned
        titleLabel.textColor = owned ? .white : .white.withAlphaComponent(0.75)

        if item.playCount > 0 {
            playCountLabel.text = Self.abbreviated(item.playCount)
            playCountLabel.isHidden = false
        } else {
            playCountLabel.isHidden = true
        }

        isAccessibilityElement = true
        accessibilityLabel = item.name
        accessibilityValue = owned
            ? String(localized: "In your library. Double tap to play from here through the rest of popular tracks.")
            : String(localized: "Not in your library")
        accessibilityTraits = owned ? .button : .staticText
    }

    static func abbreviated(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: String(localized: "%.1fM plays"), Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: String(localized: "%.0fK plays"), Double(count) / 1_000)
        }
        return String(localized: "\(count) plays")
    }
}

/// A loading or empty-state cell for the enrichment sections, with a spinner
/// while data is in flight and a dimmed message once it settles.
final class DetailMessageCell: UICollectionViewCell {

    let spinner = UIActivityIndicatorView(style: .medium)
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        spinner.color = .white.withAlphaComponent(0.6)
        spinner.hidesWhenStopped = true

        label.font = .scaled(.subheadline, size: 14, weight: .regular)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white.withAlphaComponent(0.5)
        label.numberOfLines = 0
        label.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with item: DetailMessageItem) {
        label.text = item.text
        if item.isLoading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        isAccessibilityElement = true
        accessibilityLabel = item.text
    }
}
