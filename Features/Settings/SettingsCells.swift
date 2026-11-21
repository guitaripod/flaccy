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

    func configure(selected: AppAppearance, locked: Bool) {
        segmented.selectedSegmentIndex = selected.rawValue
        segmented.isEnabled = !locked
    }

    @objc func changed() {
        guard let appearance = AppAppearance(rawValue: segmented.selectedSegmentIndex) else { return }
        onChange?(appearance)
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

/// The row at the top of Settings, drawn like the account row of the system Settings app: the
/// Flaccy mark, the plan in large type and what it means beneath, opening the plan page.
final class SettingsPlanCell: UITableViewCell {

    static let reuseID = "SettingsPlanCell"

    private let mark = UIImageView(image: SettingsHeaderView.brandGlyph())
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        accessibilityIdentifier = "settings.row.plan"
        accessibilityTraits = .button
        isAccessibilityElement = true

        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.layer.themedCornerRadius = 14
        mark.layer.cornerCurve = .continuous
        mark.clipsToBounds = true

        titleLabel.font = .scaled(.title3, size: 20, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .flaccySecondaryLabel
        subtitleLabel.numberOfLines = 0

        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        labels.axis = .vertical
        labels.spacing = 2
        let row = UIStackView(arrangedSubviews: [mark, labels])
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 58),
            mark.heightAnchor.constraint(equalToConstant: 58),
            row.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ summary: SettingsViewController.PlanSummary) {
        titleLabel.text = summary.title
        subtitleLabel.text = summary.subtitle
        subtitleLabel.isHidden = summary.subtitle.isEmpty
        accessibilityLabel = summary.title
        accessibilityValue = summary.subtitle
    }
}
