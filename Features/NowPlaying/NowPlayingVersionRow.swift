import UIKit

/// The line under the playing song's title that tells which version it is: the
/// New mix chip while the newest version is recent, and the day and time the
/// file was exported once the song has been re-exported.
final class NowPlayingVersionRow: UIStackView {

    private let chip = NewMixChipView()
    private let exportedLabel = UILabel()
    private let filler = UIView()

    init() {
        super.init(frame: .zero)
        axis = .horizontal
        alignment = .center
        spacing = 8
        exportedLabel.font = .scaled(.caption1, size: 12, weight: .regular)
        exportedLabel.adjustsFontForContentSizeCategory = true
        exportedLabel.textColor = .white.withAlphaComponent(0.5)
        exportedLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filler.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        filler.setContentCompressionResistancePriority(.fittingSizeLevel, for: .horizontal)
        for view in [chip, exportedLabel, filler] { addArrangedSubview(view) }
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        isHidden = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func configure(with track: Track?) {
        let version = track.flatMap { Library.shared.version(of: $0) }
        let newMix = version?.showsNewMix() ?? false
        let exported = version?.exportedLine
        chip.isHidden = !newMix
        exportedLabel.text = exported
        exportedLabel.isHidden = exported == nil
        isHidden = !newMix && exported == nil
        accessibilityLabel = [newMix ? TrackVersionCopy.newMix : nil, exported]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}
