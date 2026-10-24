import UIKit

final class ArtistHeaderCell: UICollectionViewCell {

    var onBioToggle: (() -> Void)?
    var onPlayAll: (() -> Void)?
    var onShuffleAll: (() -> Void)?
    var onStartStation: (() -> Void)?

    let genreChipsHolder = UIView()
    let photoContainer = UIView()
    let artistImageView = UIImageView()
    let nameLabel = UILabel()
    let genreLabel = UILabel()
    let statsLabel = UILabel()
    let bioLabel = UILabel()
    let readMoreButton = UIButton(type: .system)
    let detailsStack = UIStackView()
    let heroStack = UIStackView()
    var stackedDetailsWidth: NSLayoutConstraint?
    var isWideHeader = false
    var bioExpanded = false
    var showsFallbackImage = false
    var genreChipsShown = false

    static let imageSize: CGFloat = 132

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPhotoHero()

        nameLabel.font = .scaled(.title1, size: 28, weight: .bold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 2
        nameLabel.textAlignment = .center

        genreLabel.font = .scaled(.subheadline, size: 15, weight: .medium)
        genreLabel.adjustsFontForContentSizeCategory = true
        genreLabel.textColor = .white.withAlphaComponent(0.7)
        genreLabel.textAlignment = .center

        statsLabel.font = .scaled(.footnote, size: 13, weight: .regular)
        statsLabel.adjustsFontForContentSizeCategory = true
        statsLabel.textColor = .white.withAlphaComponent(0.5)
        statsLabel.textAlignment = .center

        bioLabel.font = .scaled(.subheadline, size: 15, weight: .regular)
        bioLabel.adjustsFontForContentSizeCategory = true
        bioLabel.textColor = .white.withAlphaComponent(0.7)
        bioLabel.numberOfLines = 4

        readMoreButton.setTitle(String(localized: "Read more"), for: .normal)
        readMoreButton.titleLabel?.font = .scaled(.footnote, size: 13, weight: .semibold)
        readMoreButton.titleLabel?.adjustsFontForContentSizeCategory = true
        readMoreButton.setTitleColor(.white, for: .normal)
        readMoreButton.contentHorizontalAlignment = .leading
        readMoreButton.accessibilityHint = String(localized: "Expands the artist biography")
        readMoreButton.addAction(UIAction { [weak self] _ in self?.toggleBio() }, for: .touchUpInside)

        let bioStack = UIStackView(arrangedSubviews: [bioLabel, readMoreButton])
        bioStack.axis = .vertical
        bioStack.spacing = 4

        let actionRow = buildActionRow()
        let stationRow = buildStationRow()
        genreChipsHolder.isHidden = true

        detailsStack.addArrangedSubview(nameLabel)
        detailsStack.addArrangedSubview(genreLabel)
        detailsStack.addArrangedSubview(statsLabel)
        detailsStack.addArrangedSubview(genreChipsHolder)
        detailsStack.addArrangedSubview(actionRow)
        detailsStack.addArrangedSubview(stationRow)
        detailsStack.axis = .vertical
        detailsStack.spacing = 8
        detailsStack.setCustomSpacing(4, after: nameLabel)
        detailsStack.setCustomSpacing(4, after: genreLabel)
        detailsStack.setCustomSpacing(14, after: statsLabel)
        detailsStack.setCustomSpacing(16, after: genreChipsHolder)
        detailsStack.setCustomSpacing(10, after: actionRow)
        detailsStack.alignment = .center

        heroStack.addArrangedSubview(photoContainer)
        heroStack.addArrangedSubview(detailsStack)
        heroStack.axis = .vertical
        heroStack.spacing = 16
        heroStack.alignment = .center

        let mainStack = UIStackView(arrangedSubviews: [heroStack, bioStack])
        mainStack.axis = .vertical
        mainStack.spacing = 20
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mainStack)

        let bioStackWidth = bioStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        let heroWidth = heroStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        let actionRowWidth = actionRow.widthAnchor.constraint(equalTo: detailsStack.widthAnchor)
        let stationRowWidth = stationRow.widthAnchor.constraint(equalTo: detailsStack.widthAnchor)
        let chipsWidth = genreChipsHolder.widthAnchor.constraint(equalTo: detailsStack.widthAnchor)
        stackedDetailsWidth = detailsStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        for constraint in [bioStackWidth, heroWidth, actionRowWidth, stationRowWidth, chipsWidth, stackedDetailsWidth!] {
            constraint.priority = .defaultHigh
        }

        NSLayoutConstraint.activate([
            photoContainer.widthAnchor.constraint(equalToConstant: Self.imageSize),
            photoContainer.heightAnchor.constraint(equalToConstant: Self.imageSize),
            bioStackWidth,
            heroWidth,
            actionRowWidth,
            stationRowWidth,
            chipsWidth,
            stackedDetailsWidth!,
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    /// Wide cells put the portrait beside the name, stats and buttons, with
    /// the text leading-aligned; narrow ones keep the centred column. Decided
    /// from the width the layout proposes, before the cell is measured.
    func applyHeaderLayout(forWidth width: CGFloat) {
        let wide = width >= 500
        guard wide != isWideHeader else { return }
        isWideHeader = wide
        heroStack.axis = wide ? .horizontal : .vertical
        heroStack.spacing = wide ? 28 : 16
        detailsStack.alignment = wide ? .leading : .center
        stackedDetailsWidth?.isActive = !wide
        let alignment: NSTextAlignment = wide ? .natural : .center
        for label in [nameLabel, genreLabel, statsLabel] { label.textAlignment = alignment }
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        applyHeaderLayout(forWidth: layoutAttributes.size.width)
        return super.preferredLayoutAttributesFitting(layoutAttributes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setupPhotoHero() {
        photoContainer.layer.shadowColor = UIColor.black.cgColor
        photoContainer.layer.shadowOpacity = 0.45
        photoContainer.layer.shadowOffset = CGSize(width: 0, height: 10)
        photoContainer.layer.shadowRadius = 22

        artistImageView.contentMode = .scaleAspectFill
        artistImageView.clipsToBounds = true
        artistImageView.layer.cornerRadius = Self.imageSize / 2
        artistImageView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        artistImageView.tintColor = UIColor.white.withAlphaComponent(0.35)
        artistImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .ultraLight)
        artistImageView.translatesAutoresizingMaskIntoConstraints = false
        photoContainer.addSubview(artistImageView)
        NSLayoutConstraint.activate([
            artistImageView.topAnchor.constraint(equalTo: photoContainer.topAnchor),
            artistImageView.leadingAnchor.constraint(equalTo: photoContainer.leadingAnchor),
            artistImageView.trailingAnchor.constraint(equalTo: photoContainer.trailingAnchor),
            artistImageView.bottomAnchor.constraint(equalTo: photoContainer.bottomAnchor),
        ])
    }

    override func layoutSubviews() {
        applyHeaderLayout(forWidth: bounds.width)
        super.layoutSubviews()
        photoContainer.layer.shadowPath = UIBezierPath(ovalIn: photoContainer.bounds).cgPath
    }

    func buildActionRow() -> UIView {
        let play = LiquidGlass.actionCapsule(title: String(localized: "Play All"), systemImage: "play.fill") { [weak self] in
            self?.onPlayAll?()
        }
        let shuffle = LiquidGlass.actionCapsule(title: String(localized: "Shuffle All"), systemImage: "shuffle") { [weak self] in
            self?.onShuffleAll?()
        }
        let row = UIStackView(arrangedSubviews: [play, shuffle])
        row.spacing = 10
        row.distribution = .fillEqually
        return LiquidGlass.grouping(row)
    }

    /// A full-width glass capsule seeding a library radio station from this
    /// artist, the signature local-discovery entry point.
    func buildStationRow() -> UIView {
        let station = LiquidGlass.actionCapsule(title: String(localized: "Start Station"), systemImage: "dot.radiowaves.left.and.right") { [weak self] in
            self?.onStartStation?()
        }
        station.accessibilityHint = String(localized: "Plays a station of similar music from your library")
        let row = UIStackView(arrangedSubviews: [station])
        row.axis = .horizontal
        row.distribution = .fill
        return LiquidGlass.grouping(row)
    }

    func applyGenreChips(_ genres: [String]) {
        genreChipsHolder.subviews.forEach { $0.removeFromSuperview() }
        guard !genres.isEmpty else {
            genreChipsHolder.isHidden = true
            genreChipsShown = false
            return
        }
        let row = DetailChip.chipsRow(genres)
        row.translatesAutoresizingMaskIntoConstraints = false
        genreChipsHolder.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: genreChipsHolder.topAnchor),
            row.bottomAnchor.constraint(equalTo: genreChipsHolder.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: genreChipsHolder.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: genreChipsHolder.trailingAnchor),
        ])
        genreChipsHolder.isHidden = false

        let shouldFade = !genreChipsShown && !UIAccessibility.isReduceMotionEnabled
        genreChipsShown = true
        guard shouldFade else { return }
        row.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
            row.alpha = 1
        }
    }

    func toggleBio() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        bioExpanded.toggle()
        bioLabel.numberOfLines = bioExpanded ? 0 : 4
        readMoreButton.setTitle(bioExpanded ? String(localized: "Read less") : String(localized: "Read more"), for: .normal)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.6) {
            self.onBioToggle?()
        }
    }

    func configure(with info: ArtistHeaderInfo, artistPhoto: UIImage?) {
        nameLabel.text = info.name
        photoContainer.isAccessibilityElement = true
        photoContainer.accessibilityLabel = String(localized: "Photo of \(info.name)")
        setHeroImage(artistPhoto ?? info.artwork, isArtistPhoto: artistPhoto != nil, info: info)

        if let genre = info.genre, !genre.isEmpty {
            genreLabel.text = genre
            genreLabel.isHidden = false
        } else {
            genreLabel.isHidden = true
        }

        statsLabel.text = String(localized: "\(info.albumCount) albums \u{00B7} \(info.trackCount) tracks")

        applyGenreChips(info.genres)

        if let bio = info.bio, !bio.isEmpty {
            bioLabel.text = bio
            bioLabel.isHidden = false
            readMoreButton.isHidden = false
        } else {
            bioLabel.isHidden = true
            readMoreButton.isHidden = true
        }
    }

    /// Applies the hero image, crossfading when a real artist photo replaces
    /// the album-artwork placeholder; falls back to a symbol and a lazy
    /// artwork load when nothing is available yet.
    func setHeroImage(_ image: UIImage?, isArtistPhoto: Bool, info: ArtistHeaderInfo) {
        if let image {
            let apply = {
                self.artistImageView.contentMode = .scaleAspectFill
                self.artistImageView.image = image
            }
            if isArtistPhoto, artistImageView.image != nil, !showsFallbackImage, !UIAccessibility.isReduceMotionEnabled {
                UIView.transition(with: artistImageView, duration: 0.3, options: [.transitionCrossDissolve], animations: apply)
            } else {
                apply()
            }
            showsFallbackImage = false
            return
        }
        showsFallbackImage = true
        artistImageView.contentMode = .center
        artistImageView.image = UIImage(systemName: "person.crop.circle.fill")
        guard let albumTitle = info.firstAlbumTitle else { return }
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: albumTitle, artist: info.name) { [weak self] image in
            guard let self, let image, self.showsFallbackImage else { return }
            self.artistImageView.contentMode = .scaleAspectFill
            self.artistImageView.image = image
        }
    }
}
