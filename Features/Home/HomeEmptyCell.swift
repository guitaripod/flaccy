import UIKit

enum HomeEmptyAction {
    case addMusic
    case addSample
    case computerGuide
}

/// What Home shows for a library with nothing in it: the same invitation as
/// the Library's own empty state, carried over its actions.
final class HomeEmptyCell: UICollectionViewCell {

    static let reuseID = "HomeEmptyCell"

    var onAction: ((HomeEmptyAction) -> Void)?

    private let iconView = UIImageView(image: UIImage(systemName: "music.note.list"))
    private let messageLabel = UILabel()
    private let addButton = UIButton(type: .system)
    private let sampleButton = UIButton(type: .system)
    private let guideButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.tintColor = .tertiaryLabel
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 56, weight: .thin)
        iconView.contentMode = .scaleAspectFit
        messageLabel.text = String(localized: "Add songs or whole folders from iCloud Drive, a USB drive, or a network share you've connected in the Files app.")
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center

        var add = UIButton.Configuration.borderedProminent()
        add.title = String(localized: "Add Music")
        add.image = UIImage(systemName: "plus")
        add.imagePadding = 8
        add.cornerStyle = .large
        addButton.configuration = add
        addButton.addAction(UIAction { [weak self] _ in self?.onAction?(.addMusic) }, for: .touchUpInside)

        sampleButton.addAction(UIAction { [weak self] _ in self?.onAction?(.addSample) }, for: .touchUpInside)

        var guide = UIButton.Configuration.plain()
        guide.title = String(localized: "Moving music from a computer")
        guide.image = UIImage(systemName: "laptopcomputer.and.iphone")
        guide.imagePadding = 6
        guide.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline)
            return attributes
        }
        guideButton.configuration = guide
        guideButton.addAction(UIAction { [weak self] _ in self?.onAction?(.computerGuide) }, for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [addButton, sampleButton])
        buttons.axis = .vertical
        buttons.spacing = 10
        let stack = UIStackView(arrangedSubviews: [iconView, messageLabel, buttons, guideButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill
        stack.setCustomSpacing(24, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 32),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -32),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(sample: UIButton.Configuration?) {
        sampleButton.configuration = sample
        sampleButton.isEnabled = !(sample?.showsActivityIndicator ?? false)
    }
}
