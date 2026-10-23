import FlaccyCore
import UIKit

final class AlbumTrackCell: UITableViewCell {

    static let reuseID = "AlbumTrackCell"

    var onToggleLove: (() -> Void)?
    var hasQualityBadge = false

    let numberLabel = UILabel()
    let barsView = NowPlayingBarsView()
    let trackTitleLabel = UILabel()
    let qualityLabel = UILabel()
    let lovedButton = UIButton(type: .system)
    let durationLabel = UILabel()

    override func layoutSubviews() {
        super.layoutSubviews()
        let hidden = !hasQualityBadge || contentView.bounds.width < 400
        if qualityLabel.isHidden != hidden { qualityLabel.isHidden = hidden }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let selection = UIView()
        selection.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        selectedBackgroundView = selection

        numberLabel.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 15, weight: .regular), maximumPointSize: 24)
        numberLabel.adjustsFontForContentSizeCategory = true
        numberLabel.textColor = .white.withAlphaComponent(0.45)
        numberLabel.textAlignment = .center

        barsView.isHidden = true

        trackTitleLabel.font = .scaled(.body, size: 16, weight: .regular)
        trackTitleLabel.adjustsFontForContentSizeCategory = true
        trackTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trackTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        qualityLabel.font = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .monospacedSystemFont(ofSize: 10, weight: .semibold), maximumPointSize: 16)
        qualityLabel.adjustsFontForContentSizeCategory = true
        qualityLabel.textColor = .white.withAlphaComponent(0.6)
        qualityLabel.setContentHuggingPriority(.required, for: .horizontal)
        qualityLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        lovedButton.setContentHuggingPriority(.required, for: .horizontal)
        lovedButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        lovedButton.tintColor = .systemPink
        lovedButton.addAction(UIAction { [weak self] _ in self?.onToggleLove?() }, for: .touchUpInside)
        lovedButton.widthAnchor.constraint(equalToConstant: 30).isActive = true

        durationLabel.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .regular), maximumPointSize: 22)
        durationLabel.adjustsFontForContentSizeCategory = true
        durationLabel.textColor = .white.withAlphaComponent(0.45)
        durationLabel.textAlignment = .right

        let numberContainer = UIView()
        numberContainer.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        barsView.translatesAutoresizingMaskIntoConstraints = false
        numberContainer.addSubview(numberLabel)
        numberContainer.addSubview(barsView)

        NSLayoutConstraint.activate([
            numberLabel.topAnchor.constraint(equalTo: numberContainer.topAnchor),
            numberLabel.bottomAnchor.constraint(equalTo: numberContainer.bottomAnchor),
            numberLabel.leadingAnchor.constraint(equalTo: numberContainer.leadingAnchor),
            numberLabel.trailingAnchor.constraint(equalTo: numberContainer.trailingAnchor),
            barsView.centerXAnchor.constraint(equalTo: numberContainer.centerXAnchor),
            barsView.centerYAnchor.constraint(equalTo: numberContainer.centerYAnchor),
            barsView.widthAnchor.constraint(equalToConstant: 16),
            barsView.heightAnchor.constraint(equalToConstant: 14),
        ])

        let stack = UIStackView(arrangedSubviews: [numberContainer, trackTitleLabel, qualityLabel, lovedButton, durationLabel])
        stack.spacing = 10
        stack.alignment = .center
        stack.setCustomSpacing(4, after: lovedButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            numberContainer.widthAnchor.constraint(equalToConstant: 28),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with track: Track, index: Int, isCurrent: Bool, isPlaying: Bool, loved: Bool, accent: UIColor) {
        numberLabel.text = track.trackNumber > 0 ? "\(track.trackNumber)" : "\(index + 1)"
        trackTitleLabel.text = track.title
        let minutes = Int(track.duration) / 60
        let seconds = Int(track.duration) % 60
        durationLabel.text = String(format: "%d:%02d", minutes, seconds)

        hasQualityBadge = track.qualityBadge != nil
        qualityLabel.text = track.qualityBadge
        qualityLabel.isHidden = !hasQualityBadge || contentView.bounds.width < 400

        let heart = UIImage(
            systemName: loved ? "heart.fill" : "heart",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        lovedButton.setImage(heart, for: .normal)
        lovedButton.tintColor = loved ? .systemPink : .white.withAlphaComponent(0.5)
        lovedButton.accessibilityLabel = loved ? String(localized: "Loved") : String(localized: "Not loved")
        lovedButton.accessibilityHint = loved
            ? String(localized: "Double tap to unlove this track")
            : String(localized: "Double tap to love this track")

        numberLabel.isHidden = isCurrent
        barsView.isHidden = !isCurrent
        barsView.tintColor = accent
        barsView.setAnimating(isPlaying)
        trackTitleLabel.textColor = isCurrent ? accent : .white
        trackTitleLabel.font = .scaled(.body, size: 16, weight: isCurrent ? .semibold : .regular)
        accessibilityValue = isCurrent ? (isPlaying ? String(localized: "Now playing") : String(localized: "Paused")) : nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggleLove = nil
    }
}
