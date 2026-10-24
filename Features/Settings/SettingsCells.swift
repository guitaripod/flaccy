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
