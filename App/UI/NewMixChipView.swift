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

/// A song title with the New mix chip and the downloaded mark. In a regular-width row they
/// follow the title on its line and the title is the part that gives way; in a compact row they
/// sit on a line of their own under the title, so a short title keeps its width.
final class TitleWithChipView: UIStackView {

    let titleLabel: UILabel
    private let chip = NewMixChipView()
    private let mark = DownloadedMarkView()
    private let underline = UIStackView()
    private let filler = UIView()
    private let underlineFiller = UIView()
    private var isCompactLayout: Bool?

    init(titleLabel: UILabel) {
        self.titleLabel = titleLabel
        super.init(frame: .zero)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for spacer in [filler, underlineFiller] {
            spacer.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
        }
        underline.axis = .horizontal
        underline.alignment = .center
        underline.spacing = 6
        chip.isHidden = true
        mark.isHidden = true
        arrange()
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: TitleWithChipView, _) in
            self.arrange()
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func setNewMix(_ shows: Bool) {
        guard chip.isHidden == shows else { return }
        chip.isHidden = !shows
        updateUnderlineVisibility()
    }

    func setDownloaded(_ shows: Bool) {
        guard mark.isHidden == shows else { return }
        mark.isHidden = !shows
        updateUnderlineVisibility()
    }

    private func arrange() {
        let compact = traitCollection.horizontalSizeClass == .compact
        guard compact != isCompactLayout else { return }
        isCompactLayout = compact
        for view in arrangedSubviews { removeArrangedSubview(view); view.removeFromSuperview() }
        for view in underline.arrangedSubviews { underline.removeArrangedSubview(view); view.removeFromSuperview() }
        if compact {
            axis = .vertical
            alignment = .leading
            spacing = 2
            underline.addArrangedSubview(chip)
            underline.addArrangedSubview(mark)
            underline.addArrangedSubview(underlineFiller)
            addArrangedSubview(titleLabel)
            addArrangedSubview(underline)
            updateUnderlineVisibility()
        } else {
            axis = .horizontal
            alignment = .center
            spacing = 6
            addArrangedSubview(titleLabel)
            addArrangedSubview(chip)
            addArrangedSubview(mark)
            addArrangedSubview(filler)
        }
    }

    private func updateUnderlineVisibility() {
        underline.isHidden = chip.isHidden && mark.isHidden
    }
}
