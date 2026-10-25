import UIKit

/// A section's title, with an optional trailing action such as See All.
final class HomeSectionHeaderView: UICollectionReusableView {

    static let reuseID = "HomeSectionHeaderView"
    static let kind = UICollectionView.elementKindSectionHeader

    private let titleLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    var onAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .scaled(.title3, size: 22, weight: .bold, maxSize: 30)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.scaled(.subheadline, size: 15, weight: .semibold, maxSize: 21)
            return attributes
        }
        actionButton.configuration = configuration
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.onAction?()
        }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [titleLabel, actionButton])
        row.axis = .horizontal
        row.alignment = .lastBaseline
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, actionTitle: String? = nil, onAction: (() -> Void)? = nil) {
        titleLabel.text = title
        actionButton.configuration?.title = actionTitle
        actionButton.isHidden = actionTitle == nil
        actionButton.accessibilityLabel = actionTitle.map { "\($0), \(title)" }
        self.onAction = onAction
    }
}

/// Hosts one of the screen's long-lived banners, the runway line or the
/// library status line, edge to edge.
final class HomeBannerCell: UICollectionViewCell {

    static let reuseID = "HomeBannerCell"

    func host(_ banner: UIView) {
        guard banner.superview !== contentView else { return }
        banner.removeFromSuperview()
        banner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: contentView.topAnchor),
            banner.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            banner.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }
}

/// The centered Edit Home capsule at the foot of the page.
final class HomeEditFooterCell: UICollectionViewCell {

    static let reuseID = "HomeEditFooterCell"
    var onTap: (() -> Void)?
    private let button = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        var configuration = UIButton.Configuration.plain()
        configuration.title = HomeCopy.editHome
        configuration.image = UIImage(systemName: "slider.horizontal.3")
        configuration.imagePadding = 8
        configuration.baseForegroundColor = .label
        configuration.cornerStyle = .capsule
        configuration.background.backgroundColor = UIColor.label.withAlphaComponent(0.1)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.scaled(.subheadline, size: 15, weight: .semibold, maxSize: 21)
            return attributes
        }
        button.configuration = configuration
        button.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.onTap?()
        }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
