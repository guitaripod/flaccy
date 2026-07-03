import ImageIO
import UIKit

/// A UIImageView that loads local album art (via AlbumArtworkCache) or a remote
/// URL (via ImageCache), guarding against cell reuse with a per-request token.
///
/// All decoding and downsampling happens off the main thread; the decoded
/// thumbnails are cached so scrolling never pays a synchronous decode cost.
final class AsyncImageView: UIImageView {

    private static let maxPixelSize: CGFloat = 600

    private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 256
        return cache
    }()

    private static let decodeQueue = DispatchQueue(
        label: "com.midgarcorp.flaccy.recap.decode",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private var token = UUID()

    convenience init() { self.init(frame: .zero) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        backgroundColor = UIColor.white.withAlphaComponent(0.06)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setRemote(_ urlString: String?, placeholder: UIImage?) {
        let current = UUID()
        token = current
        image = placeholder
        guard let urlString, let url = URL(string: urlString) else { return }
        let thumbKey = "remote:\(urlString)" as NSString
        if let thumb = Self.thumbnailCache.object(forKey: thumbKey) { image = thumb; return }

        Self.decodeQueue.async { [weak self] in
            guard let self else { return }
            if let cached = ImageCache.shared.image(forKey: urlString), let thumb = Self.prepared(cached) {
                self.deliver(thumb, key: thumbKey, token: current)
                return
            }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self, let data, let thumb = Self.downsampled(from: data) else { return }
                ImageCache.shared.store(data: data, forKey: urlString)
                self.deliver(thumb, key: thumbKey, token: current)
            }.resume()
        }
    }

    func setAlbum(title: String, artist: String, remoteURL: String?, placeholder: UIImage?) {
        let current = UUID()
        token = current
        image = placeholder
        let thumbKey = "album:\(title)\u{0}\(artist)" as NSString
        if let thumb = Self.thumbnailCache.object(forKey: thumbKey) { image = thumb; return }

        if let cached = AlbumArtworkCache.shared.artwork(forAlbum: title, artist: artist) {
            Self.decodeQueue.async { [weak self] in
                guard let self, let thumb = Self.prepared(cached) else { return }
                self.deliver(thumb, key: thumbKey, token: current)
            }
            return
        }

        AlbumArtworkCache.shared.loadArtwork(forAlbum: title, artist: artist) { [weak self] image in
            guard let self, self.token == current else { return }
            guard let image else {
                self.setRemote(remoteURL, placeholder: placeholder)
                return
            }
            Self.decodeQueue.async { [weak self] in
                guard let self, let thumb = Self.prepared(image) else { return }
                self.deliver(thumb, key: thumbKey, token: current)
            }
        }
    }

    private func deliver(_ image: UIImage, key: NSString, token current: UUID) {
        Self.thumbnailCache.setObject(image, forKey: key)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.token == current else { return }
            self.set(image, animated: true)
        }
    }

    private static func downsampled(from data: Data) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return UIImage(data: data)?.preparingForDisplay() }
        return UIImage(cgImage: cgImage)
    }

    private static func prepared(_ image: UIImage) -> UIImage? {
        let longestPixels = max(image.size.width, image.size.height) * image.scale
        guard longestPixels > maxPixelSize else { return image.preparingForDisplay() ?? image }
        let ratio = maxPixelSize / longestPixels
        let targetPixels = CGSize(
            width: image.size.width * image.scale * ratio,
            height: image.size.height * image.scale * ratio
        )
        return image.preparingThumbnail(of: targetPixels) ?? image.preparingForDisplay() ?? image
    }

    private func set(_ image: UIImage, animated: Bool) {
        guard animated, !UIAccessibility.isReduceMotionEnabled else { self.image = image; return }
        UIView.transition(with: self, duration: 0.2, options: .transitionCrossDissolve) { self.image = image }
    }
}

/// Shared number formatting: grouped counts and a compact minutes-to-hours label.
enum RecapFormat {
    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func count(_ value: Int) -> String {
        decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

private func recapCard(cornerRadius: CGFloat = 22) -> UIView {
    let card = UIView()
    if UIAccessibility.isReduceTransparencyEnabled {
        card.backgroundColor = UIColor.white.withAlphaComponent(0.1)
    } else {
        card.backgroundColor = UIColor.white.withAlphaComponent(0.06)
    }
    card.layer.cornerRadius = cornerRadius
    card.layer.cornerCurve = .continuous
    card.layer.borderWidth = 0.5
    card.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
    return card
}

/// Section header shown above the top-lists and visualizations.
final class RecapHeaderView: UICollectionReusableView {
    static let reuseID = "RecapHeaderView"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .scaled(.title3, size: 20, weight: .bold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String) {
        label.text = title
        accessibilityTraits = .header
    }
}

final class ProfileCell: UICollectionViewCell {
    static let reuseID = "ProfileCell"

    private let avatar = AsyncImageView()
    private let nameLabel = UILabel()
    private let sinceLabel = UILabel()
    private let playsValue = UILabel()
    private let minutesValue = UILabel()

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

    private static func statColumn(value: UILabel, caption: String) -> UIStackView {
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
        accessibilityLabel = "\(item.username). \(item.sinceText ?? ""). \(RecapFormat.count(item.totalPlays)) plays, \(RecapFormat.count(item.totalMinutes)) minutes listened."
    }
}

final class ImportBannerCell: UICollectionViewCell {
    static let reuseID = "ImportBannerCell"

    private let card = recapCard(cornerRadius: 18)
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let chevron = UIImageView(image: UIImage(systemName: "arrow.down.circle.fill"))
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

    @objc private func handleTap() { onTap?() }

    func configure(state: RecapImportState) {
        switch state {
        case .available:
            titleLabel.text = "Import Last.fm history"
            subtitleLabel.text = "Backfill your stats with everything you scrobbled before installing."
            spinner.stopAnimating()
            chevron.isHidden = false
            card.isUserInteractionEnabled = true
            accessibilityHint = "Double tap to import"
        case .importing:
            titleLabel.text = "Importing history\u{2026}"
            subtitleLabel.text = "This can take a moment. You can keep browsing."
            spinner.startAnimating()
            chevron.isHidden = true
            card.isUserInteractionEnabled = false
            accessibilityHint = nil
        case .done:
            titleLabel.text = "History imported"
            subtitleLabel.text = "Your stats now include your full listening history."
            spinner.stopAnimating()
            chevron.isHidden = true
            card.isUserInteractionEnabled = false
            accessibilityHint = nil
        case .unavailable:
            titleLabel.text = "Connect Last.fm to import"
            subtitleLabel.text = "Sign in from Settings to backfill your history."
            spinner.stopAnimating()
            chevron.isHidden = true
            card.isUserInteractionEnabled = false
            accessibilityHint = nil
        }
        isAccessibilityElement = true
        accessibilityLabel = titleLabel.text
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
    }
}

final class ArtistCardCell: UICollectionViewCell {
    static let reuseID = "ArtistCardCell"

    private let rankLabel = UILabel()
    private let initialLabel = UILabel()
    private let nameLabel = UILabel()
    private let playsLabel = UILabel()
    private let disc = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        disc.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        disc.layer.cornerRadius = 40
        disc.translatesAutoresizingMaskIntoConstraints = false

        initialLabel.font = .scaled(.largeTitle, size: 30, weight: .bold)
        initialLabel.textColor = .white
        initialLabel.textAlignment = .center
        initialLabel.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(initialLabel)

        rankLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        rankLabel.textColor = .black
        rankLabel.textAlignment = .center
        rankLabel.backgroundColor = .white
        rankLabel.layer.cornerRadius = 11
        rankLabel.layer.masksToBounds = true
        rankLabel.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .scaled(.footnote, size: 13, weight: .semibold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .white
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2

        playsLabel.font = .scaled(.caption2, size: 11, weight: .regular)
        playsLabel.adjustsFontForContentSizeCategory = true
        playsLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        playsLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [disc, nameLabel, playsLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.addSubview(rankLabel)

        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: 80),
            disc.heightAnchor.constraint(equalToConstant: 80),
            initialLabel.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            initialLabel.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            rankLabel.widthAnchor.constraint(equalToConstant: 22),
            rankLabel.heightAnchor.constraint(equalToConstant: 22),
            rankLabel.centerXAnchor.constraint(equalTo: disc.trailingAnchor, constant: -8),
            rankLabel.centerYAnchor.constraint(equalTo: disc.topAnchor, constant: 8),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: RecapArtistItem, tint: UIColor) {
        initialLabel.text = String(item.name.prefix(1)).uppercased()
        nameLabel.text = item.name
        playsLabel.text = "\(RecapFormat.compact(item.playCount)) plays"
        rankLabel.text = "\(item.rank)"
        disc.backgroundColor = tint.withAlphaComponent(0.28)
        isAccessibilityElement = true
        accessibilityLabel = "Number \(item.rank), \(item.name), \(item.playCount) plays"
    }
}

final class AlbumCoverCell: UICollectionViewCell {
    static let reuseID = "AlbumCoverCell"

    private let cover = AsyncImageView()
    private let nameLabel = UILabel()
    private let rankLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        cover.layer.cornerRadius = 10
        cover.layer.cornerCurve = .continuous
        cover.translatesAutoresizingMaskIntoConstraints = false

        rankLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        rankLabel.textColor = .white
        rankLabel.textAlignment = .center
        rankLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        rankLabel.layer.cornerRadius = 9
        rankLabel.layer.masksToBounds = true
        rankLabel.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .scaled(.caption2, size: 11, weight: .medium)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        nameLabel.numberOfLines = 1

        let stack = UIStackView(arrangedSubviews: [cover, nameLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.addSubview(rankLabel)

        NSLayoutConstraint.activate([
            cover.widthAnchor.constraint(equalTo: cover.heightAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rankLabel.widthAnchor.constraint(equalToConstant: 18),
            rankLabel.heightAnchor.constraint(equalToConstant: 18),
            rankLabel.leadingAnchor.constraint(equalTo: cover.leadingAnchor, constant: 5),
            rankLabel.topAnchor.constraint(equalTo: cover.topAnchor, constant: 5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: AlbumItem) {
        nameLabel.text = item.name
        rankLabel.text = "\(item.rank)"
        cover.setAlbum(title: item.name, artist: item.artist, remoteURL: item.imageURL, placeholder: UIImage(systemName: "square.stack"))
        isAccessibilityElement = true
        accessibilityLabel = "Number \(item.rank), \(item.name) by \(item.artist), \(item.playCount) plays"
    }
}

final class TrackRowCell: UICollectionViewCell {
    static let reuseID = "TrackRowCell"

    private let rankLabel = UILabel()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let playsLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        rankLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .bold)
        rankLabel.textAlignment = .center
        rankLabel.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .scaled(.body, size: 16, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        artistLabel.font = .scaled(.caption1, size: 12, weight: .regular)
        artistLabel.adjustsFontForContentSizeCategory = true
        artistLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        artistLabel.numberOfLines = 1

        playsLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        playsLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        playsLabel.textAlignment = .right
        playsLabel.setContentHuggingPriority(.required, for: .horizontal)

        let info = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        info.axis = .vertical
        info.spacing = 1

        let row = UIStackView(arrangedSubviews: [rankLabel, info, playsLabel])
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            rankLabel.widthAnchor.constraint(equalToConstant: 28),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -9),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func medalColor(for rank: Int) -> UIColor? {
        switch rank {
        case 1: .systemYellow
        case 2: .systemGray2
        case 3: .systemBrown
        default: nil
        }
    }

    func configure(_ item: TrackItem) {
        rankLabel.text = "\(item.rank)"
        rankLabel.textColor = Self.medalColor(for: item.rank) ?? UIColor.white.withAlphaComponent(0.5)
        titleLabel.text = item.name
        artistLabel.text = item.artist
        playsLabel.text = RecapFormat.compact(item.playCount)
        isAccessibilityElement = true
        accessibilityLabel = "Number \(item.rank), \(item.name) by \(item.artist), \(item.playCount) plays"
    }
}

final class ClockCell: UICollectionViewCell {
    static let reuseID = "ClockCell"
    private let card = recapCard()
    private let clock = ListeningClockView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.translatesAutoresizingMaskIntoConstraints = false
        clock.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)
        card.addSubview(clock)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            clock.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            clock.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            clock.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            clock.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: ClockItem, tint: UIColor) {
        clock.configure(buckets: item.buckets, tint: tint)
    }
}

final class StreakCell: UICollectionViewCell {
    static let reuseID = "StreakCell"
    private let card = recapCard()
    private let flameLabel = UILabel()
    private let streakValue = UILabel()
    private let streakCaption = UILabel()
    private let heatmap = HeatmapView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        flameLabel.text = "\u{1F525}"
        flameLabel.font = .systemFont(ofSize: 30)

        streakValue.font = .scaled(.largeTitle, size: 34, weight: .heavy)
        streakValue.adjustsFontForContentSizeCategory = true
        streakValue.textColor = .white

        streakCaption.font = .scaled(.caption1, size: 12, weight: .semibold)
        streakCaption.adjustsFontForContentSizeCategory = true
        streakCaption.textColor = UIColor.white.withAlphaComponent(0.55)

        let valueRow = UIStackView(arrangedSubviews: [streakValue, streakCaption])
        valueRow.axis = .vertical
        valueRow.spacing = 0

        let topRow = UIStackView(arrangedSubviews: [flameLabel, valueRow])
        topRow.axis = .horizontal
        topRow.spacing = 10
        topRow.alignment = .center

        heatmap.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [topRow, heatmap])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: StreakItem, tint: UIColor) {
        let days = item.streakDays
        streakValue.text = "\(days)"
        streakCaption.text = days == 1 ? "DAY STREAK" : "DAY STREAK"
        heatmap.configure(counts: item.heatmap, tint: tint)
        isAccessibilityElement = false
    }
}

final class PersonaCell: UICollectionViewCell {
    static let reuseID = "PersonaCell"

    private let gradient = CAGradientLayer()
    private let card = UIView()
    private let iconView = UIImageView()
    private let personaLabel = UILabel()
    private let blurbLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.addSublayer(gradient)

        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .bold)

        personaLabel.font = .scaled(.title1, size: 28, weight: .heavy)
        personaLabel.adjustsFontForContentSizeCategory = true
        personaLabel.textColor = .white

        blurbLabel.font = .scaled(.subheadline, size: 15, weight: .medium)
        blurbLabel.adjustsFontForContentSizeCategory = true
        blurbLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        blurbLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [iconView, personaLabel, blurbLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        contentView.addSubview(card)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = card.bounds
    }

    func configure(_ item: PersonaItem, palette: ArtworkPalette) {
        personaLabel.text = item.persona
        blurbLabel.text = RecapPersona.blurb(for: item.persona)
        iconView.image = UIImage(systemName: RecapPersona.symbol(for: item.persona))
        let colors = palette.colors
        let first = (colors.first ?? .systemIndigo).cgColor
        let second = (colors.count > 2 ? colors[2] : colors.last ?? .systemPurple).cgColor
        gradient.colors = [first, second]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        isAccessibilityElement = true
        accessibilityLabel = "Your persona: \(item.persona). \(RecapPersona.blurb(for: item.persona))"
    }
}

final class PeriodSelectorCell: UICollectionViewCell {
    static let reuseID = "PeriodSelectorCell"

    private var capsules: [ChartPeriod: GlassCapsule] = [:]
    private let stack = UIStackView()
    private var selectedPeriod: ChartPeriod = .allTime
    var onSelect: ((ChartPeriod) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.spacing = 8
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        for period in RecapPeriods.all {
            let button = UIButton(type: .system)
            button.setTitle(period.shortName, for: .normal)
            button.titleLabel?.font = .scaled(.footnote, size: 13, weight: .semibold)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.setTitleColor(.white, for: .normal)
            button.accessibilityLabel = period.displayName
            button.addAction(UIAction { [weak self] _ in
                UISelectionFeedbackGenerator().selectionChanged()
                self?.onSelect?(period)
            }, for: .touchUpInside)
            let capsule = GlassCapsule(hosting: button, height: 38)
            capsule.isAccessibilityElement = false
            capsules[period] = capsule
            stack.addArrangedSubview(capsule)
        }
    }

    func configure(selected: ChartPeriod) {
        self.selectedPeriod = selected
        for (period, capsule) in capsules {
            let active = period == selected
            capsule.setActive(active, animated: !UIAccessibility.isReduceMotionEnabled)
            if let button = capsule.subviews.compactMap({ $0 as? UIButton }).first {
                button.accessibilityTraits = active ? [.button, .selected] : .button
            }
        }
    }
}

/// The 7D / 1M / 3M / 1Y / All subset of ChartPeriod the Recap surfaces.
enum RecapPeriods {
    static let all: [ChartPeriod] = [.week, .month, .threeMonths, .year, .allTime]
}
