import ImageIO
import MidgarCore
import UIKit

/// Section header shown above the top-lists and visualizations.
final class RecapHeaderView: UICollectionReusableView {
    static let reuseID = "RecapHeaderView"
    let label = UILabel()
    let actions = UIStackView()
    var onPlay: (() -> Void)?
    var onShuffle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .scaled(.title3, size: 20, weight: .bold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let play = LiquidGlass.iconCapsule(systemImage: "play.fill", accessibilityLabel: String(localized: "Play"), height: 34) { [weak self] in
            self?.onPlay?()
        }
        let shuffle = LiquidGlass.iconCapsule(systemImage: "shuffle", accessibilityLabel: String(localized: "Shuffle"), height: 34) { [weak self] in
            self?.onShuffle?()
        }
        actions.axis = .horizontal
        actions.spacing = 8
        actions.addArrangedSubview(play)
        actions.addArrangedSubview(shuffle)
        actions.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [label, UIView(), actions])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onPlay = nil
        onShuffle = nil
    }

    func configure(title: String, onPlay: (() -> Void)? = nil, onShuffle: (() -> Void)? = nil) {
        label.text = title
        accessibilityTraits = .header
        self.onPlay = onPlay
        self.onShuffle = onShuffle
        actions.isHidden = onPlay == nil && onShuffle == nil
    }
}

final class ProfileCell: UICollectionViewCell {
    static let reuseID = "ProfileCell"

    let avatar = AsyncImageView()
    let nameLabel = UILabel()
    let sinceLabel = UILabel()
    let playsValue = UILabel()
    let minutesValue = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        avatar.layer.cornerRadius = 34
        avatar.layer.borderWidth = 1
        avatar.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        avatar.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .scaled(.largeTitle, size: 28, weight: .heavy)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 1

        sinceLabel.font = .scaled(.subheadline, size: 14, weight: .medium)
        sinceLabel.adjustsFontForContentSizeCategory = true
        sinceLabel.textColor = UIColor.white.withAlphaComponent(0.6)

        let identity = UIStackView(arrangedSubviews: [nameLabel, sinceLabel])
        identity.axis = .vertical
        identity.spacing = 2

        let topRow = UIStackView(arrangedSubviews: [avatar, identity])
        topRow.axis = .horizontal
        topRow.spacing = 14
        topRow.alignment = .center

        let playsStat = Self.statColumn(value: playsValue, caption: "plays")
        let minutesStat = Self.statColumn(value: minutesValue, caption: "minutes")
        let statsRow = UIStackView(arrangedSubviews: [playsStat, minutesStat])
        statsRow.axis = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.spacing = 12

        let statsCard = recapCard()
        statsCard.translatesAutoresizingMaskIntoConstraints = false
        statsRow.translatesAutoresizingMaskIntoConstraints = false
        statsCard.addSubview(statsRow)
        NSLayoutConstraint.activate([
            statsRow.topAnchor.constraint(equalTo: statsCard.topAnchor, constant: 18),
            statsRow.bottomAnchor.constraint(equalTo: statsCard.bottomAnchor, constant: -18),
            statsRow.leadingAnchor.constraint(equalTo: statsCard.leadingAnchor, constant: 8),
            statsRow.trailingAnchor.constraint(equalTo: statsCard.trailingAnchor, constant: -8),
        ])

        let main = UIStackView(arrangedSubviews: [topRow, statsCard])
        main.axis = .vertical
        main.spacing = 16
        main.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(main)

        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 68),
            avatar.heightAnchor.constraint(equalToConstant: 68),
            main.topAnchor.constraint(equalTo: contentView.topAnchor),
            main.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            main.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            main.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func statColumn(value: UILabel, caption: String) -> UIStackView {
        value.font = .scaled(.largeTitle, size: 34, weight: .heavy, maxSize: 44)
        value.adjustsFontForContentSizeCategory = true
        value.textColor = .white
        value.textAlignment = .center
        value.adjustsFontSizeToFitWidth = true
        value.minimumScaleFactor = 0.5

        let captionLabel = UILabel()
        captionLabel.font = .scaled(.caption1, size: 12, weight: .semibold)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        captionLabel.textAlignment = .center
        captionLabel.text = caption.uppercased()

        let stack = UIStackView(arrangedSubviews: [value, captionLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .center
        return stack
    }

    func configure(_ item: ProfileItem) {
        nameLabel.text = item.username
        sinceLabel.text = item.sinceText
        sinceLabel.isHidden = item.sinceText == nil
        playsValue.text = RecapFormat.count(item.totalPlays)
        minutesValue.text = RecapFormat.count(item.totalMinutes)
        avatar.setRemote(item.avatarURL, placeholder: UIImage(systemName: "person.crop.circle.fill"))

        isAccessibilityElement = true
        accessibilityLabel = String(localized: "\(item.username). \(item.sinceText ?? ""). \(RecapFormat.count(item.totalPlays)) plays, \(RecapFormat.count(item.totalMinutes)) minutes listened.")
    }
}

final class ImportBannerCell: UICollectionViewCell {
    static let reuseID = "ImportBannerCell"

    let card = recapCard(cornerRadius: 18)
    let iconView = UIImageView()
    let titleLabel = UILabel()
    let subtitleLabel = UILabel()
    let spinner = UIActivityIndicatorView(style: .medium)
    let chevron = UIImageView(image: UIImage(systemName: "arrow.down.circle.fill"))
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        iconView.image = UIImage(systemName: "clock.arrow.circlepath")
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)

        titleLabel.font = .scaled(.subheadline, size: 15, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white

        subtitleLabel.font = .scaled(.caption1, size: 12, weight: .regular)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        subtitleLabel.numberOfLines = 2

        chevron.tintColor = UIColor.white.withAlphaComponent(0.8)
        chevron.contentMode = .scaleAspectFit
        spinner.color = .white
        spinner.hidesWhenStopped = true

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 1

        let trailing = UIStackView(arrangedSubviews: [spinner, chevron])
        trailing.axis = .horizontal

        let row = UIStackView(arrangedSubviews: [iconView, textStack, trailing])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        contentView.addSubview(card)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 28),
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        card.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func handleTap() { onTap?() }

    func configure(state: RecapImportState) {
        switch state {
        case .available:
            titleLabel.text = String(localized: "Import Last.fm history")
            subtitleLabel.text = String(localized: "Backfill your stats with everything you scrobbled before installing.")
            spinner.stopAnimating()
            chevron.isHidden = false
            card.isUserInteractionEnabled = true
            accessibilityHint = String(localized: "Double tap to import")
        case .importing(let imported):
            titleLabel.text = String(localized: "Importing history\u{2026}")
            subtitleLabel.text = imported > 0
                ? String(localized: "\(RecapFormat.count(imported)) scrobbles imported so far\u{2026}")
                : String(localized: "This can take a moment. You can keep browsing.")
            spinner.startAnimating()
            chevron.isHidden = true
            card.isUserInteractionEnabled = false
            accessibilityHint = nil
        case .done(let imported):
            titleLabel.text = String(localized: "History imported")
            subtitleLabel.text = imported > 0
                ? String(localized: "Imported \(RecapFormat.count(imported)) scrobbles.")
                : String(localized: "Your stats now include your full listening history.")
            spinner.stopAnimating()
            chevron.isHidden = true
            card.isUserInteractionEnabled = false
            accessibilityHint = nil
        case .unavailable:
            titleLabel.text = String(localized: "Connect Last.fm to import")
            subtitleLabel.text = String(localized: "Sign in from Settings to backfill your history.")
            spinner.stopAnimating()
            chevron.isHidden = true
            card.isUserInteractionEnabled = false
            accessibilityHint = nil
        }
        isAccessibilityElement = true
        accessibilityLabel = [titleLabel.text, subtitleLabel.text].compactMap { $0 }.joined(separator: ". ")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
    }
}
