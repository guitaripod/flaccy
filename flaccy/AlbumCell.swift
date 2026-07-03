import UIKit

final class AlbumCell: UICollectionViewCell {

    static let reuseID = "AlbumCell"

    private let artworkContainer = UIView()
    private let artworkView = UIImageView()
    private let shimmerLayer = CAGradientLayer()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let metaLabel = UILabel()
    private let qualityBadge = QualityBadgeView(size: .compact)
    private let lovedBadge = UIImageView()

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
        artworkView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 32, weight: .ultraLight)
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(artworkView)

        setupShimmerLayer()
        setupOverlayBadges()

        titleLabel.font = .scaled(.footnote, size: 14, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        artistLabel.font = .scaled(.caption1, size: 12, weight: .regular)
        artistLabel.adjustsFontForContentSizeCategory = true
        artistLabel.textColor = .secondaryLabel
        artistLabel.numberOfLines = 1
        artistLabel.lineBreakMode = .byTruncatingTail

        metaLabel.font = .scaled(.caption2, size: 10, weight: .regular)
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.textColor = .tertiaryLabel
        metaLabel.numberOfLines = 1
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.isHidden = true

        let stack = UIStackView(arrangedSubviews: [artworkContainer, titleLabel, artistLabel, metaLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(2, after: artistLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let aspectRatio = artworkContainer.heightAnchor.constraint(equalTo: artworkContainer.widthAnchor)
        aspectRatio.priority = .defaultHigh

        NSLayoutConstraint.activate([
            aspectRatio,
            artworkView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            artworkView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])

        if traitCollection.userInterfaceIdiom == .pad || ProcessInfo.processInfo.isiOSAppOnMac {
            addInteraction(UIPointerInteraction(delegate: nil))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            setPressed(isHighlighted)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        artworkContainer.layer.shadowPath = UIBezierPath(
            roundedRect: artworkView.frame, cornerRadius: 10
        ).cgPath
        shimmerLayer.frame = artworkView.bounds
    }

    func configure(with album: Album, qualityTrack: Track?, loved: Bool) {
        configure(with: album)
        qualityBadge.configure(with: qualityTrack)
        lovedBadge.isHidden = !loved
    }

    func configure(with album: Album) {
        titleLabel.text = album.title
        artistLabel.text = album.artist

        if let artwork = album.artwork {
            applyArtwork(artwork)
        } else if let cached = AlbumArtworkCache.shared.artwork(forAlbum: album.title, artist: album.artist) {
            applyArtwork(cached)
        } else {
            beginSkeleton()
            AlbumArtworkCache.shared.loadArtwork(forAlbum: album.title, artist: album.artist) { [weak self] image in
                guard let self, self.titleLabel.text == album.title else { return }
                if let image {
                    self.applyArtwork(image)
                } else {
                    self.showPlaceholder()
                }
            }
        }

        var metaParts: [String] = []
        if let year = album.year, !year.isEmpty { metaParts.append(year) }
        if let genre = album.genre, !genre.isEmpty { metaParts.append(genre) }
        metaLabel.text = metaParts.joined(separator: " \u{00B7} ")
        metaLabel.isHidden = metaParts.isEmpty
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        endSkeleton()
        artworkView.image = nil
        titleLabel.text = nil
        artistLabel.text = nil
        metaLabel.text = nil
        metaLabel.isHidden = true
        qualityBadge.isHidden = true
        lovedBadge.isHidden = true
        contentView.transform = .identity
    }

    /// Springs the whole cell content down to 0.96 on touch and back on release,
    /// matching the Now Playing press language; instant under Reduce Motion.
    private func setPressed(_ pressed: Bool) {
        let transform = pressed ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
        guard !UIAccessibility.isReduceMotionEnabled else {
            contentView.transform = transform
            return
        }
        let animator = UIViewPropertyAnimator(duration: pressed ? 0.16 : 0.32, dampingRatio: pressed ? 1 : 0.72) {
            self.contentView.transform = transform
        }
        animator.startAnimation()
    }

    /// Adds the corner overlays: a quality pill on the lower-leading edge of the
    /// artwork and a loved heart on the lower-trailing edge.
    private func setupOverlayBadges() {
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

        NSLayoutConstraint.activate([
            qualityBadge.leadingAnchor.constraint(equalTo: artworkView.leadingAnchor, constant: 5),
            qualityBadge.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: -5),
            qualityBadge.trailingAnchor.constraint(lessThanOrEqualTo: lovedBadge.leadingAnchor, constant: -4),
            lovedBadge.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: -6),
            lovedBadge.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: -6),
        ])
    }

    private func applyArtwork(_ image: UIImage) {
        endSkeleton()
        artworkView.contentMode = .scaleAspectFill
        artworkView.image = image
    }

    private func showPlaceholder() {
        endSkeleton()
        artworkView.contentMode = .center
        artworkView.image = UIImage(systemName: "music.note")
    }

    private func setupShimmerLayer() {
        let base = UIColor.tertiarySystemFill.cgColor
        let highlight = UIColor.quaternarySystemFill.cgColor
        shimmerLayer.colors = [base, highlight, base]
        shimmerLayer.locations = [0, 0.5, 1]
        shimmerLayer.startPoint = CGPoint(x: 0, y: 0.4)
        shimmerLayer.endPoint = CGPoint(x: 1, y: 0.6)
        shimmerLayer.cornerRadius = 10
        shimmerLayer.cornerCurve = .continuous
        shimmerLayer.isHidden = true
        artworkView.layer.addSublayer(shimmerLayer)
    }

    /// Shows an animated shimmer over the artwork slot while artwork resolves,
    /// falling back to a static fill under Reduce Motion.
    private func beginSkeleton() {
        artworkView.image = nil
        artworkView.contentMode = .scaleAspectFill
        shimmerLayer.isHidden = false
        shimmerLayer.frame = artworkView.bounds
        guard !UIAccessibility.isReduceMotionEnabled, shimmerLayer.animation(forKey: "shimmer") == nil else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-1.0, -0.5, 0.0]
        sweep.toValue = [1.0, 1.5, 2.0]
        sweep.duration = 1.1
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmerLayer.add(sweep, forKey: "shimmer")
    }

    private func endSkeleton() {
        shimmerLayer.removeAnimation(forKey: "shimmer")
        shimmerLayer.isHidden = true
    }
}
