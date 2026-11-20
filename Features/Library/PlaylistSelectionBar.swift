import UIKit

/// The glass bar that floats over a playlist page while songs are chosen:
/// queue them, add them to another playlist, or take them out of this one.
/// It sits above the tab bar and the mini player, which stay where they are.
final class PlaylistSelectionBar: UIView {

    let queueButton = PlaylistSelectionBar.button(symbol: "text.line.first.and.arrowtriangle.forward", title: String(localized: "Queue"))
    let addButton = PlaylistSelectionBar.button(symbol: "text.badge.plus", title: String(localized: "Add to…"))
    let removeButton = PlaylistSelectionBar.button(symbol: "minus.circle", title: String(localized: "Remove"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        let glass = UIAccessibility.isReduceTransparencyEnabled
            ? Self.solidBackground()
            : LiquidGlass.view(cornerRadius: 30)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        removeButton.configuration?.baseForegroundColor = .systemRed
        for button in [queueButton, addButton] { button.showsMenuAsPrimaryAction = true }
        let row = UIStackView(arrangedSubviews: [queueButton, addButton, removeButton])
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 6)
        accessibilityIdentifier = "playlist.selectionBar"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setEnabled(hasSongs: Bool, hasPlayable: Bool) {
        queueButton.isEnabled = hasPlayable
        addButton.isEnabled = hasPlayable
        removeButton.isEnabled = hasSongs
    }

    private static func button(symbol: String, title: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        configuration.title = title
        configuration.imagePlacement = .top
        configuration.imagePadding = 4
        configuration.baseForegroundColor = .label
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = UIFont.preferredFont(forTextStyle: .caption1)
            return updated
        }
        let button = UIButton(configuration: configuration)
        button.maximumContentSizeCategory = .accessibilityMedium
        return button
    }

    private static func solidBackground() -> UIView {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 30
        view.layer.cornerCurve = .continuous
        return view
    }
}
