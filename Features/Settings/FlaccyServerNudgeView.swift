import UIKit

/// The footer of Settings > Servers for a person with no server: the invitation and a close button.
final class FlaccyServerNudgeView: UIView {

    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(frame: .zero)
        let label = UILabel()
        label.text = FlaccyServerNudge.text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "xmark.circle.fill")
        configuration.baseForegroundColor = .tertiaryLabel
        let close = UIButton(configuration: configuration)
        close.accessibilityLabel = String(localized: "Close")
        close.accessibilityHint = String(localized: "Hides this suggestion for good")
        close.accessibilityIdentifier = "settings.serversNudge.close"
        close.addAction(UIAction { [weak self] _ in self?.onClose() }, for: .touchUpInside)
        close.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [label, close])
        row.alignment = .top
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor, constant: -8),
        ])
        accessibilityIdentifier = "settings.serversNudge"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// A label with room around its text, for the small Sync badge.
final class PaddedBadgeLabel: UILabel {

    private let insets = UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}
