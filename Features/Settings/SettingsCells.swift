import AuthenticationServices
import MidgarCore
import FlaccyCore
import StoreKit
import MidgarPortal
import UIKit

/// A settings row hosting a full-width segmented control for the light/dark
/// override, applied live as the user drags across it.
final class AppearanceCell: UITableViewCell {

    static let reuseID = "AppearanceCell"

    var onChange: ((AppAppearance) -> Void)?

    let segmented = IdentifiedSegmentedControl(
        items: AppAppearance.allCases.map(\.displayName),
        identifiers: AppAppearance.allCases.map(\.accessibilityIdentifier)
    )

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.addTarget(self, action: #selector(changed), for: .valueChanged)
        contentView.addSubview(segmented)
        NSLayoutConstraint.activate([
            segmented.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            segmented.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            segmented.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            segmented.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(selected: AppAppearance) {
        segmented.selectedSegmentIndex = selected.rawValue
    }

    @objc func changed() {
        guard let appearance = AppAppearance(rawValue: segmented.selectedSegmentIndex) else { return }
        onChange?(appearance)
    }
}

/// A settings row for the accent: its name on the right of the title and one
/// round swatch per choice under it, the chosen one ringed and checked. A tap
/// applies the accent at once.
final class AccentCell: UITableViewCell {

    static let reuseID = "AccentCell"

    var onChange: ((AccentChoice) -> Void)?

    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let swatchRow = UIStackView()
    private var swatches: [AccentSwatch] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        titleLabel.text = String(localized: "Accent")
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.isAccessibilityElement = false
        valueLabel.font = .preferredFont(forTextStyle: .body)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = .secondaryLabel
        valueLabel.textAlignment = .right
        valueLabel.isAccessibilityElement = false

        let header = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        header.spacing = 8

        swatchRow.axis = .horizontal
        swatchRow.distribution = .equalSpacing
        swatchRow.alignment = .center
        for accent in AccentChoice.allCases {
            let swatch = AccentSwatch(accent: accent)
            swatch.addAction(UIAction { [weak self] _ in self?.choose(accent) }, for: .touchUpInside)
            swatchRow.addArrangedSubview(swatch)
            swatches.append(swatch)
        }

        let stack = UIStackView(arrangedSubviews: [header, swatchRow])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(selected: AccentChoice) {
        valueLabel.text = selected.displayName
        for swatch in swatches {
            swatch.isChosen = swatch.accent == selected
        }
    }

    private func choose(_ accent: AccentChoice) {
        guard swatches.first(where: \.isChosen)?.accent != accent else { return }
        configure(selected: accent)
        onChange?(accent)
    }
}

/// One round accent swatch: a disc of the accent's own color, ringed and
/// checked while it is the chosen one.
final class AccentSwatch: UIControl {

    static let side: CGFloat = 34

    let accent: AccentChoice

    var isChosen = false {
        didSet {
            ring.isHidden = !isChosen
            check.isHidden = !isChosen
            accessibilityTraits = isChosen ? [.button, .selected] : .button
        }
    }

    private let disc = UIView()
    private let ring = UIView()
    private let check = UIImageView(image: UIImage(
        systemName: "checkmark",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
    ))

    init(accent: AccentChoice) {
        self.accent = accent
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        ring.layer.borderWidth = 2
        ring.layer.cornerRadius = (Self.side + 8) / 2
        ring.isUserInteractionEnabled = false
        ring.isHidden = true
        disc.backgroundColor = accent.color
        disc.layer.cornerRadius = Self.side / 2
        disc.isUserInteractionEnabled = false
        check.tintColor = .white
        check.contentMode = .center
        check.isHidden = true
        for view in [ring, disc, check] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side + 8),
            heightAnchor.constraint(equalToConstant: Self.side + 8),
            ring.topAnchor.constraint(equalTo: topAnchor),
            ring.leadingAnchor.constraint(equalTo: leadingAnchor),
            ring.trailingAnchor.constraint(equalTo: trailingAnchor),
            ring.bottomAnchor.constraint(equalTo: bottomAnchor),
            disc.centerXAnchor.constraint(equalTo: centerXAnchor),
            disc.centerYAnchor.constraint(equalTo: centerYAnchor),
            disc.widthAnchor.constraint(equalToConstant: Self.side),
            disc.heightAnchor.constraint(equalToConstant: Self.side),
            check.centerXAnchor.constraint(equalTo: centerXAnchor),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        isAccessibilityElement = true
        accessibilityLabel = accent.displayName
        accessibilityTraits = .button
        accessibilityIdentifier = "settings.accent.\(accent.rawValue)"
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (swatch: AccentSwatch, _) in
            swatch.applyRingColor()
        }
        applyRingColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyRingColor() {
        ring.layer.borderColor = accent.color.resolvedColor(with: traitCollection).cgColor
    }

    override var isHighlighted: Bool {
        didSet { disc.alpha = isHighlighted ? 0.6 : 1 }
    }
}

/// The Midgar portal doorway as the first row of Settings: transparent, with no
/// separator or highlight of its own, so the card reads as a card rather than a
/// list row. The cell steps out of the accessibility tree so VoiceOver reaches
/// the card itself.
final class MidgarEntryCell: UITableViewCell {

    static let reuseID = "MidgarEntryCell"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundConfiguration = .clear()
        separatorInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: .greatestFiniteMagnitude)
        isAccessibilityElement = false
        MidgarEntryView(config: FlaccyMidgar.shared.portalConfig).embed(in: contentView, verticalInset: 8)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
