import UIKit

/// The capsule that marks a song whose newest version arrived recently: the
/// quality badge's shape in the accent tint, so the two read as one family.
final class NewMixChipView: UIView {

    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        label.font = .scaled(.caption2, size: 9.5, weight: .heavy)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.text = TrackVersionCopy.newMix.uppercased()
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let height: CGFloat = 17
        layer.cornerRadius = height / 2
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: height),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])

        isAccessibilityElement = false
        applyTint()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: NewMixChipView, _) in
            self.applyTint()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyTint() {
        let resolved = QualityBadgeView.losslessDynamicTint.resolvedColor(with: traitCollection)
        label.textColor = resolved
        layer.borderColor = resolved.withAlphaComponent(0.5).cgColor
        backgroundColor = resolved.withAlphaComponent(0.14)
    }
}

/// A song title followed by the New mix chip. The title is the part that
/// gives way when the row is narrow; the chip always keeps its width.
final class TitleWithChipView: UIStackView {

    let titleLabel: UILabel
    private let chip = NewMixChipView()
    private let filler = UIView()

    init(titleLabel: UILabel) {
        self.titleLabel = titleLabel
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = 6
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filler.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        filler.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
        chip.isHidden = true
        addArrangedSubview(titleLabel)
        addArrangedSubview(chip)
        addArrangedSubview(filler)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func setNewMix(_ shows: Bool) {
        guard chip.isHidden == shows else { return }
        chip.isHidden = !shows
    }
}
