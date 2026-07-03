import UIKit

nonisolated enum ArtistDetailSection: Int, CaseIterable, Sendable {
    case header
    case albums
}

nonisolated enum ArtistDetailItem: Hashable, Sendable {
    case header(ArtistHeaderInfo)
    case album(Album)
}

nonisolated struct ArtistHeaderInfo: Hashable, Sendable {
    let name: String
    let bio: String?
    let genre: String?
    let albumCount: Int
    let trackCount: Int
    let artwork: UIImage?
    let firstAlbumTitle: String?

    nonisolated static func == (lhs: ArtistHeaderInfo, rhs: ArtistHeaderInfo) -> Bool {
        lhs.name == rhs.name
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

final class ArtistDetailViewController: UIViewController {

    enum AlbumSort: String, CaseIterable {
        case title, year, trackCount

        var displayName: String {
            switch self {
            case .title: "Title"
            case .year: "Year"
            case .trackCount: "Track Count"
            }
        }

        var icon: String {
            switch self {
            case .title: "textformat.abc"
            case .year: "calendar"
            case .trackCount: "number"
            }
        }
    }

    private let artistName: String
    private var albums: [Album]
    private var albumSort: AlbumSort = AlbumSort(rawValue: UserDefaults.standard.string(forKey: "artistDetailAlbumSort") ?? "") ?? .title
    private var bio: String?
    private var artistPhoto: UIImage?
    private var artistPhotoTask: Task<Void, Never>?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<ArtistDetailSection, ArtistDetailItem>!
    private let backdropView = AmbientPaletteBackdropView()
    private var hasAnimatedAppearance = false
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)

    init(artistName: String, albums: [Album]) {
        self.artistName = artistName
        self.albums = albums
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        artistPhotoTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        navigationItem.largeTitleDisplayMode = .never

        setupBackdrop()
        setupSortMenu()
        fetchArtistInfo()
        sortAlbums()
        setupCollectionView()
        configureDataSource()
        applySnapshot()
        fetchArtistPhoto()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !hasAnimatedAppearance, !UIAccessibility.isReduceMotionEnabled {
            collectionView.alpha = 0
            collectionView.transform = CGAffineTransform(translationX: 0, y: 16)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasAnimatedAppearance else { return }
        hasAnimatedAppearance = true
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.84) { [self] in
            collectionView.alpha = 1
            collectionView.transform = .identity
        }
        animator.startAnimation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdropView.frame = view.bounds
    }

    private func setupBackdrop() {
        backdropView.frame = view.bounds
        view.addSubview(backdropView)
        applyPalette(from: initialArtwork(), animated: false)
    }

    private func initialArtwork() -> UIImage? {
        guard let album = albums.first else { return nil }
        return album.artwork ?? AlbumArtworkCache.shared.artwork(forAlbum: album.title, artist: album.artist)
    }

    private func applyPalette(from image: UIImage?, animated: Bool) {
        ArtworkPaletteExtractor.palette(
            for: image,
            cacheKey: "artist\0\(artistName.lowercased())",
            fallbackSeed: artistName
        ) { [weak self] palette in
            self?.backdropView.apply(palette, animated: animated)
        }
    }

    /// Resolves the artist photo through the caching service, then swaps it into
    /// the hero and re-derives the ambient palette from the photo itself.
    private func fetchArtistPhoto() {
        artistPhotoTask = Task { [weak self] in
            guard let self else { return }
            let image = await ArtistImageService.shared.image(for: self.artistName)
            guard !Task.isCancelled, let image else { return }
            self.artistPhoto = image
            ArtworkPaletteExtractor.palette(
                for: image,
                cacheKey: "artistphoto\0\(self.artistName.lowercased())",
                fallbackSeed: self.artistName
            ) { [weak self] palette in
                self?.backdropView.apply(palette, animated: true)
            }
            var snapshot = self.dataSource.snapshot()
            let headerItems = snapshot.itemIdentifiers(inSection: .header)
            snapshot.reconfigureItems(headerItems)
            await self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    private func setupSortMenu() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.up.arrow.down"),
            menu: buildSortMenu()
        )
    }

    private func buildSortMenu() -> UIMenu {
        let actions = AlbumSort.allCases.map { sort in
            UIAction(
                title: sort.displayName,
                image: UIImage(systemName: sort.icon),
                state: albumSort == sort ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self.albumSort = sort
                UserDefaults.standard.set(sort.rawValue, forKey: "artistDetailAlbumSort")
                self.setupSortMenu()
                self.sortAlbums()
                self.applySnapshot()
            }
        }
        return UIMenu(title: "Sort By", children: actions)
    }

    private func sortAlbums() {
        switch albumSort {
        case .title:
            albums.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .year:
            albums.sort {
                let y0 = $0.year ?? "9999"
                let y1 = $1.year ?? "9999"
                return y0 == y1 ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending : y0 < y1
            }
        case .trackCount:
            albums.sort { $0.tracks.count > $1.tracks.count }
        }
    }

    private func fetchArtistInfo() {
        guard let artist = try? DatabaseManager.shared.fetchArtist(name: artistName) else { return }
        if let rawBio = artist.bio, !rawBio.isEmpty {
            bio = rawBio
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func setupCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: createLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.backgroundColor = .clear
        collectionView.indicatorStyle = .white
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func createLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { sectionIndex, _ in
            guard let section = ArtistDetailSection(rawValue: sectionIndex) else { return nil }

            switch section {
            case .header:
                let itemSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(320)
                )
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                let groupSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(320)
                )
                let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 24, bottom: 8, trailing: 24)
                return layoutSection

            case .albums:
                let itemSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(0.5),
                    heightDimension: .estimated(240)
                )
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                let groupSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(240)
                )
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item, item])
                group.interItemSpacing = .fixed(12)
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.interGroupSpacing = 16
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)

                let headerSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(32)
                )
                let sectionHeader = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: headerSize,
                    elementKind: UICollectionView.elementKindSectionHeader,
                    alignment: .top
                )
                layoutSection.boundarySupplementaryItems = [sectionHeader]
                return layoutSection
            }
        }
    }

    private func configureDataSource() {
        let headerCellRegistration = UICollectionView.CellRegistration<ArtistHeaderCell, ArtistHeaderInfo> { [weak self] cell, _, info in
            cell.configure(with: info, artistPhoto: self?.artistPhoto)
            cell.onBioToggle = {
                self?.collectionView.collectionViewLayout.invalidateLayout()
            }
            cell.onPlayAll = { self?.playAll(shuffled: false) }
            cell.onShuffleAll = { self?.playAll(shuffled: true) }
        }

        let albumCellRegistration = UICollectionView.CellRegistration<AlbumCell, Album> { cell, _, album in
            cell.configure(with: album)
        }

        let sectionHeaderRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { supplementaryView, _, _ in
            var config = UIListContentConfiguration.plainHeader()
            config.text = "Albums"
            config.textProperties.font = .scaled(.title3, size: 20, weight: .bold)
            config.textProperties.color = .white
            supplementaryView.contentConfiguration = config
            supplementaryView.backgroundConfiguration = .clear()
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .header(let info):
                return collectionView.dequeueConfiguredReusableCell(using: headerCellRegistration, for: indexPath, item: info)
            case .album(let album):
                return collectionView.dequeueConfiguredReusableCell(using: albumCellRegistration, for: indexPath, item: album)
            }
        }

        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            guard ArtistDetailSection(rawValue: indexPath.section) == .albums else { return nil }
            return collectionView.dequeueConfiguredReusableSupplementary(using: sectionHeaderRegistration, for: indexPath)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<ArtistDetailSection, ArtistDetailItem>()
        snapshot.appendSections(ArtistDetailSection.allCases)

        let totalTracks = albums.reduce(0) { $0 + $1.tracks.count }
        let genre = albums.compactMap(\.genre).first
        let firstAlbum = albums.first
        let artwork = firstAlbum.flatMap { album in
            album.artwork ?? AlbumArtworkCache.shared.artwork(forAlbum: album.title, artist: album.artist)
        }

        let headerInfo = ArtistHeaderInfo(
            name: artistName,
            bio: bio,
            genre: genre,
            albumCount: albums.count,
            trackCount: totalTracks,
            artwork: artwork,
            firstAlbumTitle: firstAlbum?.title
        )
        snapshot.appendItems([.header(headerInfo)], toSection: .header)
        snapshot.appendItems(albums.map { .album($0) }, toSection: .albums)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func playAll(shuffled: Bool) {
        var tracks = albums.flatMap(\.tracks)
        guard !tracks.isEmpty else { return }
        if shuffled {
            tracks.shuffle()
        }
        impactMedium.impactOccurred()
        AudioPlayer.shared.play(tracks, startingAt: 0)
    }
}

extension ArtistDetailViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .album(let album):
            impactLight.impactOccurred()
            let vc = AlbumDetailViewController(album: album)
            navigationController?.pushViewController(vc, animated: true)
        case .header:
            break
        }
    }
}

final class ArtistHeaderCell: UICollectionViewCell {

    var onBioToggle: (() -> Void)?
    var onPlayAll: (() -> Void)?
    var onShuffleAll: (() -> Void)?

    private let photoContainer = UIView()
    private let artistImageView = UIImageView()
    private let nameLabel = UILabel()
    private let genreLabel = UILabel()
    private let statsLabel = UILabel()
    private let bioLabel = UILabel()
    private let readMoreButton = UIButton(type: .system)
    private var bioExpanded = false
    private var showsFallbackImage = false

    private static let imageSize: CGFloat = 132

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

        readMoreButton.setTitle("Read more", for: .normal)
        readMoreButton.titleLabel?.font = .scaled(.footnote, size: 13, weight: .semibold)
        readMoreButton.titleLabel?.adjustsFontForContentSizeCategory = true
        readMoreButton.setTitleColor(.white, for: .normal)
        readMoreButton.contentHorizontalAlignment = .leading
        readMoreButton.accessibilityHint = "Expands the artist biography"
        readMoreButton.addAction(UIAction { [weak self] _ in self?.toggleBio() }, for: .touchUpInside)

        let bioStack = UIStackView(arrangedSubviews: [bioLabel, readMoreButton])
        bioStack.axis = .vertical
        bioStack.spacing = 4

        let actionRow = buildActionRow()

        let mainStack = UIStackView(arrangedSubviews: [photoContainer, nameLabel, genreLabel, statsLabel, actionRow, bioStack])
        mainStack.axis = .vertical
        mainStack.spacing = 8
        mainStack.setCustomSpacing(16, after: photoContainer)
        mainStack.setCustomSpacing(4, after: nameLabel)
        mainStack.setCustomSpacing(4, after: genreLabel)
        mainStack.setCustomSpacing(16, after: statsLabel)
        mainStack.setCustomSpacing(20, after: actionRow)
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mainStack)

        let bioStackWidth = bioStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        bioStackWidth.priority = .defaultHigh
        let actionRowWidth = actionRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        actionRowWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            photoContainer.widthAnchor.constraint(equalToConstant: Self.imageSize),
            photoContainer.heightAnchor.constraint(equalToConstant: Self.imageSize),
            bioStackWidth,
            actionRowWidth,
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupPhotoHero() {
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
        super.layoutSubviews()
        photoContainer.layer.shadowPath = UIBezierPath(ovalIn: photoContainer.bounds).cgPath
    }

    private func buildActionRow() -> UIView {
        let play = LiquidGlass.actionCapsule(title: "Play All", systemImage: "play.fill") { [weak self] in
            self?.onPlayAll?()
        }
        let shuffle = LiquidGlass.actionCapsule(title: "Shuffle All", systemImage: "shuffle") { [weak self] in
            self?.onShuffleAll?()
        }
        let row = UIStackView(arrangedSubviews: [play, shuffle])
        row.spacing = 10
        row.distribution = .fillEqually
        return LiquidGlass.grouping(row)
    }

    private func toggleBio() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        bioExpanded.toggle()
        bioLabel.numberOfLines = bioExpanded ? 0 : 4
        readMoreButton.setTitle(bioExpanded ? "Read less" : "Read more", for: .normal)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.6) {
            self.onBioToggle?()
        }
    }

    func configure(with info: ArtistHeaderInfo, artistPhoto: UIImage?) {
        nameLabel.text = info.name
        photoContainer.isAccessibilityElement = true
        photoContainer.accessibilityLabel = "Photo of \(info.name)"
        setHeroImage(artistPhoto ?? info.artwork, isArtistPhoto: artistPhoto != nil, info: info)

        if let genre = info.genre, !genre.isEmpty {
            genreLabel.text = genre
            genreLabel.isHidden = false
        } else {
            genreLabel.isHidden = true
        }

        let albumWord = info.albumCount == 1 ? "album" : "albums"
        let trackWord = info.trackCount == 1 ? "track" : "tracks"
        statsLabel.text = "\(info.albumCount) \(albumWord) \u{00B7} \(info.trackCount) \(trackWord)"

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
    private func setHeroImage(_ image: UIImage?, isArtistPhoto: Bool, info: ArtistHeaderInfo) {
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
        AlbumArtworkCache.shared.loadArtwork(forAlbum: albumTitle, artist: info.name) { [weak self] image in
            guard let self, let image, self.showsFallbackImage else { return }
            self.artistImageView.contentMode = .scaleAspectFill
            self.artistImageView.image = image
        }
    }
}
