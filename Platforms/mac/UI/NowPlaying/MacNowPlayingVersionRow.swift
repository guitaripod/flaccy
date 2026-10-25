import AppKit

/// The line under the playing song's title that tells which version it is: the
/// New mix chip while the newest version is recent, and the day and time the
/// file was exported once the song has been re-exported.
final class MacNowPlayingVersionRow: NSStackView {

    private let chip = MacNewMixChip()
    private let exportedLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        exportedLabel.font = .systemFont(ofSize: 12)
        exportedLabel.textColor = MacColors.tertiaryLabel
        exportedLabel.lineBreakMode = .byTruncatingTail
        exportedLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chip.isHidden = true
        exportedLabel.isHidden = true
        addArrangedSubview(chip)
        addArrangedSubview(exportedLabel)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with track: Track?) {
        let version = track.flatMap { Library.shared.version(of: $0) }
        let newMix = version?.showsNewMix() ?? false
        let exported = version?.exportedLine
        chip.isHidden = !newMix
        exportedLabel.stringValue = exported ?? ""
        exportedLabel.isHidden = exported == nil
        isHidden = !newMix && exported == nil
        exportedLabel.setAccessibilityLabel(
            [newMix ? TrackVersionCopy.newMix : nil, exported].compactMap { $0 }.joined(separator: ", ")
        )
    }
}
