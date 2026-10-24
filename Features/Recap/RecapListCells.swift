import ImageIO
import MidgarCore
import UIKit

final class ArtistCardCell: UICollectionViewCell {
    static let reuseID = "ArtistCardCell"

    let rankLabel = UILabel()
    let initialLabel = UILabel()
    let nameLabel = UILabel()
    let playsLabel = UILabel()
    let disc = UIView()
    let cover = AsyncImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        disc.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        disc.layer.cornerRadius = 40
        disc.layer.masksToBounds = true
        disc.translatesAutoresizingMaskIntoConstraints = false

        cover.layer.cornerRadius = 40
        cover.layer.masksToBounds = true
        cover.isHidden = true
        cover.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(cover)

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
            cover.topAnchor.constraint(equalTo: disc.topAnchor),
            cover.bottomAnchor.constraint(equalTo: disc.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: disc.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: disc.trailingAnchor),
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
        playsLabel.text = item.playCount > 0 ? String(localized: "\(RecapFormat.compact(item.playCount)) plays") : String(localized: "New to you")
        rankLabel.text = "\(item.rank)"
        disc.backgroundColor = tint.withAlphaComponent(0.28)

        if let title = item.artworkTitle, let artist = item.artworkArtist {
            cover.isHidden = false
            initialLabel.isHidden = true
            cover.setAlbum(title: title, artist: artist, remoteURL: nil, placeholder: nil)
        } else {
            cover.isHidden = true
            initialLabel.isHidden = false
        }

        isAccessibilityElement = true
        let ownership = item.isLocal ? String(localized: ", in your library, double tap to start a station") : ""
        accessibilityLabel = String(localized: "Number \(item.rank), \(item.name), \(item.playCount) plays\(ownership)")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cover.isHidden = true
        initialLabel.isHidden = false
    }
}

final class AlbumCoverCell: UICollectionViewCell {
    static let reuseID = "AlbumCoverCell"

    let cover = AsyncImageView()
    let nameLabel = UILabel()
    let rankLabel = UILabel()
    let playBadge = UIImageView(image: UIImage(systemName: "play.circle.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)

        cover.layer.cornerRadius = 10
        cover.layer.cornerCurve = .continuous
        cover.translatesAutoresizingMaskIntoConstraints = false

        playBadge.tintColor = .white
        playBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        playBadge.contentMode = .scaleAspectFit
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.45
        playBadge.layer.shadowRadius = 3
        playBadge.layer.shadowOffset = .zero
        playBadge.isHidden = true
        playBadge.translatesAutoresizingMaskIntoConstraints = false

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
        contentView.addSubview(playBadge)

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
            playBadge.trailingAnchor.constraint(equalTo: cover.trailingAnchor, constant: -6),
            playBadge.bottomAnchor.constraint(equalTo: cover.bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: AlbumItem) {
        nameLabel.text = item.name
        rankLabel.text = "\(item.rank)"
        playBadge.isHidden = !item.isLocal
        let artTitle = item.artworkTitle ?? item.name
        let artArtist = item.artworkArtist ?? item.artist
        let fallback: RecapArtworkQuery? = item.isLocal ? nil : .album(artist: item.artist, album: item.name)
        cover.setAlbum(title: artTitle, artist: artArtist, remoteURL: item.imageURL, placeholder: UIImage(systemName: "square.stack"), remoteFallback: fallback)
        isAccessibilityElement = true
        let ownership = item.isLocal ? String(localized: ", in your library, double tap to play") : ""
        accessibilityLabel = String(localized: "Number \(item.rank), \(item.name) by \(item.artist), \(item.playCount) plays\(ownership)")
    }
}

final class TrackRowCell: UICollectionViewCell {
    static let reuseID = "TrackRowCell"

    let rankLabel = UILabel()
    let artwork = AsyncImageView()
    let playBadge = UIImageView(image: UIImage(systemName: "play.circle.fill"))
    let titleLabel = UILabel()
    let artistLabel = UILabel()
    let playsLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        rankLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .bold)
        rankLabel.textAlignment = .center
        rankLabel.setContentHuggingPriority(.required, for: .horizontal)

        artwork.layer.cornerRadius = 6
        artwork.layer.cornerCurve = .continuous
        artwork.translatesAutoresizingMaskIntoConstraints = false

        playBadge.tintColor = .white
        playBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        playBadge.contentMode = .scaleAspectFit
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.45
        playBadge.layer.shadowRadius = 2
        playBadge.layer.shadowOffset = .zero
        playBadge.isHidden = true
        playBadge.translatesAutoresizingMaskIntoConstraints = false

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

        let row = UIStackView(arrangedSubviews: [rankLabel, artwork, info, playsLabel])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        contentView.addSubview(playBadge)

        NSLayoutConstraint.activate([
            rankLabel.widthAnchor.constraint(equalToConstant: 22),
            artwork.widthAnchor.constraint(equalToConstant: 40),
            artwork.heightAnchor.constraint(equalToConstant: 40),
            playBadge.centerXAnchor.constraint(equalTo: artwork.centerXAnchor),
            playBadge.centerYAnchor.constraint(equalTo: artwork.centerYAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func medalColor(for rank: Int) -> UIColor? {
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

        playBadge.isHidden = !item.isLocal
        contentView.alpha = item.isLocal ? 1.0 : 0.55
        let artTitle = item.artworkTitle ?? item.name
        let artArtist = item.artworkArtist ?? item.artist
        let fallback: RecapArtworkQuery? = item.isLocal ? nil : .track(artist: item.artist, track: item.name)
        artwork.setAlbum(title: artTitle, artist: artArtist, remoteURL: nil, placeholder: UIImage(systemName: "music.note"), remoteFallback: fallback)

        isAccessibilityElement = true
        let ownership = item.isLocal ? String(localized: ", in your library, double tap to play") : String(localized: ", not in your library")
        accessibilityLabel = String(localized: "Number \(item.rank), \(item.name) by \(item.artist), \(item.playCount) plays\(ownership)")
    }
}
