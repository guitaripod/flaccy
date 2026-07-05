import UIKit

/// A grid tile for a single track: album artwork with a quality pill and loved
/// heart overlay, and title / artist beneath. Mirrors AlbumCell's press language.
final class TrackGridCell: UICollectionViewCell {

    private let artworkContainer = UIView()
    private let artworkView = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let qualityBadge = QualityBadgeView(size: .compact)
    private let lovedBadge = UIImageView()
    private var currentArtworkKey: String?

    override init(frame: CGRect) {
        super.init(frame: frame)

        artworkContainer.layer.shadowColor = UIColor.black.cgColor
        artworkContainer.layer.shadowOpacity = 0.18
        artworkContainer.layer.shadowOffset = CGSize(width: 0, height: 4)
        artworkContainer.layer.shadowRadius = 10

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 10
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = .tertiarySystemFill
        artworkView.tintColor = .tertiaryLabel
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 28, weight: .ultraLight)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(artworkView)

        qualityBadge.translatesAutoresizingMaskIntoConstraints = false
        qualityBadge.isHidden = true
        artworkContainer.addSubview(qualityBadge)

        lovedBadge.image = UIImage(
            systemName: "heart.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        )
        lovedBadge.tintColor = .systemPink
        lovedBadge.translatesAutoresizingMaskIntoConstraints = false
        lovedBadge.isHidden = true
        lovedBadge.layer.shadowColor = UIColor.black.cgColor
        lovedBadge.layer.shadowOpacity = 0.35
        lovedBadge.layer.shadowRadius = 3
        lovedBadge.layer.shadowOffset = .zero
        artworkContainer.addSubview(lovedBadge)

        titleLabel.font = .scaled(.footnote, size: 14, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        artistLabel.font = .scaled(.caption1, size: 12, weight: .regular)
        artistLabel.adjustsFontForContentSizeCategory = true
        artistLabel.textColor = .secondaryLabel
        artistLabel.numberOfLines = 1
        artistLabel.lineBreakMode = .byTruncatingTail

        let stack = UIStackView(arrangedSubviews: [artworkContainer, titleLabel, artistLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(4, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let aspect = artworkContainer.heightAnchor.constraint(equalTo: artworkContainer.widthAnchor)
        aspect.priority = .defaultHigh

        NSLayoutConstraint.activate([
            aspect,
            artworkView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            artworkView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),
            qualityBadge.leadingAnchor.constraint(equalTo: artworkView.leadingAnchor, constant: 5),
            qualityBadge.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: -5),
            qualityBadge.trailingAnchor.constraint(lessThanOrEqualTo: lovedBadge.leadingAnchor, constant: -4),
            lovedBadge.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: -6),
            lovedBadge.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            let transform = isHighlighted ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
            guard !UIAccessibility.isReduceMotionEnabled else { contentView.transform = transform; return }
            UIViewPropertyAnimator(duration: isHighlighted ? 0.16 : 0.32, dampingRatio: isHighlighted ? 1 : 0.72) {
                self.contentView.transform = transform
            }.startAnimation()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        artworkContainer.layer.shadowPath = UIBezierPath(roundedRect: artworkView.frame, cornerRadius: 10).cgPath
    }

    func configure(with track: Track, loved: Bool) {
        titleLabel.text = track.title
        artistLabel.text = track.artist
        qualityBadge.configure(with: track)
        lovedBadge.isHidden = !loved

        if let cached = AlbumArtworkCache.shared.thumbnail(forAlbum: track.albumTitle, artist: track.artist) {
            artworkView.contentMode = .scaleAspectFill
            artworkView.image = cached
            currentArtworkKey = nil
        } else {
            artworkView.contentMode = .center
            artworkView.image = UIImage(systemName: "music.note")
            let key = "\(track.albumTitle)|\(track.artist)"
            currentArtworkKey = key
            AlbumArtworkCache.shared.loadThumbnail(forAlbum: track.albumTitle, artist: track.artist) { [weak self] image in
                guard let self, self.currentArtworkKey == key, let image else { return }
                self.artworkView.contentMode = .scaleAspectFill
                self.artworkView.image = image
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentArtworkKey = nil
        artworkView.image = nil
        titleLabel.text = nil
        artistLabel.text = nil
        qualityBadge.isHidden = true
        lovedBadge.isHidden = true
        contentView.transform = .identity
    }
}
