import UIKit

/// One feature as a row: its symbol on a tinted tile, its name, and a line about it.
final class ShowcaseRowView: UIView {

    init(feature: ShowcaseFeature) {
        super.init(frame: .zero)

        let symbol = UIImageView(image: UIImage(systemName: feature.symbol))
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        symbol.contentMode = .center
        symbol.tintColor = .tintColor
        symbol.translatesAutoresizingMaskIntoConstraints = false

        let tile = ShowcaseTileView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(symbol)

        let title = WelcomeViewController.label(feature.title, style: .headline)
        let detail = WelcomeViewController.label(feature.detail, style: .subheadline, color: .secondaryLabel)
        let words = UIStackView(arrangedSubviews: [title, detail])
        words.axis = .vertical
        words.spacing = 2

        let row = UIStackView(arrangedSubviews: [tile, words])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 40),
            tile.heightAnchor.constraint(equalToConstant: 40),
            symbol.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        isAccessibilityElement = true
        accessibilityLabel = "\(feature.title). \(feature.detail)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The rounded tile a row's symbol sits on, washed with the accent.
final class ShowcaseTileView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        backgroundColor = tintColor.withAlphaComponent(0.16)
    }
}
