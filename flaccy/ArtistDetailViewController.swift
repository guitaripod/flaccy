import UIKit

nonisolated enum ArtistDetailSection: Int, CaseIterable, Sendable {
    case header
    case similarArtists
    case popularTracks
    case albums

    var title: String? {
        switch self {
        case .header: nil
        case .similarArtists: "Similar Artists in Your Library"
        case .popularTracks: "Popular Tracks"
        case .albums: "Albums"
        }
    }
}

nonisolated enum ArtistDetailItem: Hashable, Sendable {
    case header(ArtistHeaderInfo)
    case similarAlbum(SimilarAlbumItem)
    case popularTrack(PopularTrackItem)
    case album(Album)
    case message(DetailMessageItem)
}

nonisolated struct SimilarAlbumItem: Hashable, Sendable {
    let album: Album
}

nonisolated struct PopularTrackItem: Hashable, Sendable {
    let name: String
    let playCount: Int
    let rank: Int
    let ownedTrack: Track?

    nonisolated static func == (lhs: PopularTrackItem, rhs: PopularTrackItem) -> Bool {
        lhs.rank == rhs.rank && lhs.name == rhs.name
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(rank)
    }
}

nonisolated struct DetailMessageItem: Hashable, Sendable {
    let id: String
    let text: String
    let isLoading: Bool
}

nonisolated struct ArtistHeaderInfo: Hashable, Sendable {
    let name: String
    let bio: String?
    let genre: String?
    let albumCount: Int
    let trackCount: Int
    let artwork: UIImage?
    let firstAlbumTitle: String?
    var genres: [String] = []

    nonisolated static func == (lhs: ArtistHeaderInfo, rhs: ArtistHeaderInfo) -> Bool {
        lhs.name == rhs.name && lhs.genres == rhs.genres
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

final class ArtistDetailViewController: UIViewController, SonglinkShareable {

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
    private var similarAlbums: [Album] = []
    private var similarLoaded = false
    private var popularTracks: [PopularTrackItem] = []
    private var popularLoaded = false
    private var genres: [String] = []
    private var enrichmentTask: Task<Void, Never>?
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
        enrichmentTask?.cancel()
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
        loadEnrichment()
    }

    /// Fetches similar-library artists, Last.fm popular tracks, and genre tags
    /// off-main, caching each, then folds them into their sections as they land.
    private func loadEnrichment() {
        let artist = artistName
        let ownedByTitle = ownedTracksByTitle()
        enrichmentTask = Task { [weak self] in
            async let similarResult = DetailEnrichmentCache.shared.similarInLibrary(artist: artist)
            async let popularResult = DetailEnrichmentCache.shared.topTracks(artist: artist, limit: 12)
            async let tagsResult = DetailEnrichmentCache.shared.topTags(artist: artist)

            let similar = await similarResult
            if !Task.isCancelled {
                self?.similarAlbums = similar
                self?.similarLoaded = true
                self?.applySnapshot()
            }

            let popular = await popularResult
            if !Task.isCancelled {
                self?.popularTracks = popular.map { entry in
                    PopularTrackItem(
                        name: entry.name,
                        playCount: entry.playCount,
                        rank: entry.rank,
                        ownedTrack: ownedByTitle[entry.name.lowercased()]
                    )
                }
                self?.popularLoaded = true
                self?.applySnapshot()
            }

            let tags = await tagsResult
            if !Task.isCancelled, !tags.isEmpty {
                self?.genres = tags
                self?.applySnapshot(animatingDifferences: !UIAccessibility.isReduceMotionEnabled)
            }
        }
    }

    private func ownedTracksByTitle() -> [String: Track] {
        var map: [String: Track] = [:]
        for track in albums.flatMap(\.tracks) {
            let key = track.title.lowercased()
            if map[key] == nil { map[key] = track }
        }
        return map
    }

    private func startStation() {
        impactMedium.impactOccurred()
        AudioPlayer.shared.startStation(seedArtist: artistName)
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
        return album.artwork ?? AlbumArtworkCache.shared.thumbnail(forAlbum: album.title, artist: album.artist)
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

            case .similarArtists:
                let itemSize = NSCollectionLayoutSize(
                    widthDimension: .absolute(150),
                    heightDimension: .absolute(206)
                )
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.orthogonalScrollingBehavior = .continuous
                layoutSection.interGroupSpacing = 12
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 24, bottom: 12, trailing: 24)
                layoutSection.boundarySupplementaryItems = [Self.sectionHeaderItem()]
                return layoutSection

            case .popularTracks:
                let itemSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(54)
                )
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.interGroupSpacing = 2
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20)
                layoutSection.boundarySupplementaryItems = [Self.sectionHeaderItem()]
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

    private static func sectionHeaderItem() -> NSCollectionLayoutBoundarySupplementaryItem {
        let headerSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .estimated(32)
        )
        return NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: headerSize,
            elementKind: UICollectionView.elementKindSectionHeader,
            alignment: .top
        )
    }

    private func configureDataSource() {
        let headerCellRegistration = UICollectionView.CellRegistration<ArtistHeaderCell, ArtistHeaderInfo> { [weak self] cell, _, info in
            cell.configure(with: info, artistPhoto: self?.artistPhoto)
            cell.onBioToggle = {
                self?.collectionView.collectionViewLayout.invalidateLayout()
            }
            cell.onPlayAll = { self?.playAll(shuffled: false) }
            cell.onShuffleAll = { self?.playAll(shuffled: true) }
            cell.onStartStation = { self?.startStation() }
        }

        let albumCellRegistration = UICollectionView.CellRegistration<AlbumCell, Album> { cell, _, album in
            cell.configure(with: album)
        }

        let similarCellRegistration = UICollectionView.CellRegistration<AlbumCell, SimilarAlbumItem> { cell, _, item in
            cell.configure(with: item.album)
        }

        let popularCellRegistration = UICollectionView.CellRegistration<PopularTrackCell, PopularTrackItem> { cell, _, item in
            cell.configure(with: item)
        }

        let messageCellRegistration = UICollectionView.CellRegistration<DetailMessageCell, DetailMessageItem> { cell, _, item in
            cell.configure(with: item)
        }

        let sectionHeaderRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { supplementaryView, _, indexPath in
            var config = UIListContentConfiguration.plainHeader()
            config.text = ArtistDetailSection(rawValue: indexPath.section)?.title
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
            case .similarAlbum(let item):
                return collectionView.dequeueConfiguredReusableCell(using: similarCellRegistration, for: indexPath, item: item)
            case .popularTrack(let item):
                return collectionView.dequeueConfiguredReusableCell(using: popularCellRegistration, for: indexPath, item: item)
            case .message(let item):
                return collectionView.dequeueConfiguredReusableCell(using: messageCellRegistration, for: indexPath, item: item)
            }
        }

        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            guard let section = ArtistDetailSection(rawValue: indexPath.section), section.title != nil else { return nil }
            return collectionView.dequeueConfiguredReusableSupplementary(using: sectionHeaderRegistration, for: indexPath)
        }
    }

    private func applySnapshot(animatingDifferences: Bool = false) {
        var snapshot = NSDiffableDataSourceSnapshot<ArtistDetailSection, ArtistDetailItem>()
        snapshot.appendSections(ArtistDetailSection.allCases)

        let totalTracks = albums.reduce(0) { $0 + $1.tracks.count }
        let genre = albums.compactMap(\.genre).first
        let firstAlbum = albums.first
        let artwork = firstAlbum.flatMap { album in
            album.artwork ?? AlbumArtworkCache.shared.thumbnail(forAlbum: album.title, artist: album.artist)
        }

        let headerInfo = ArtistHeaderInfo(
            name: artistName,
            bio: bio,
            genre: genre,
            albumCount: albums.count,
            trackCount: totalTracks,
            artwork: artwork,
            firstAlbumTitle: firstAlbum?.title,
            genres: genres
        )
        snapshot.appendItems([.header(headerInfo)], toSection: .header)
        snapshot.appendItems(similarSectionItems(), toSection: .similarArtists)
        snapshot.appendItems(popularSectionItems(), toSection: .popularTracks)
        snapshot.appendItems(albums.map { .album($0) }, toSection: .albums)
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    private func similarSectionItems() -> [ArtistDetailItem] {
        guard similarLoaded else {
            return [.message(DetailMessageItem(id: "similar.loading", text: "Finding artists in your library\u{2026}", isLoading: true))]
        }
        guard !similarAlbums.isEmpty else {
            return [.message(DetailMessageItem(id: "similar.empty", text: "No similar artists in your library yet.", isLoading: false))]
        }
        return similarAlbums.map { .similarAlbum(SimilarAlbumItem(album: $0)) }
    }

    private func popularSectionItems() -> [ArtistDetailItem] {
        guard popularLoaded else {
            return [.message(DetailMessageItem(id: "popular.loading", text: "Loading popular tracks\u{2026}", isLoading: true))]
        }
        guard !popularTracks.isEmpty else {
            return [.message(DetailMessageItem(id: "popular.empty", text: "No popular tracks available.", isLoading: false))]
        }
        return popularTracks.map { .popularTrack($0) }
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
        case .similarAlbum(let similar):
            impactLight.impactOccurred()
            let vc = AlbumDetailViewController(album: similar.album)
            navigationController?.pushViewController(vc, animated: true)
        case .popularTrack(let track):
            guard let owned = track.ownedTrack else { return }
            let queue = popularTracks.compactMap(\.ownedTrack)
            guard let startIndex = queue.firstIndex(where: { $0.fileURL == owned.fileURL }) else { return }
            impactLight.impactOccurred()
            AudioPlayer.shared.play(queue, startingAt: startIndex)
        case .header, .message:
            break
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              case .popularTrack(let item) = dataSource.itemIdentifier(for: indexPath),
              let owned = item.ownedTrack else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return TrackContextMenu.build(
                for: owned,
                in: self,
                push: { [weak self] viewController in
                    self?.navigationController?.pushViewController(viewController, animated: true)
                },
                context: TrackContextMenu.Context(hideGoToArtist: true)
            )
        }
    }
}

final class ArtistHeaderCell: UICollectionViewCell {

    var onBioToggle: (() -> Void)?
    var onPlayAll: (() -> Void)?
    var onShuffleAll: (() -> Void)?
    var onStartStation: (() -> Void)?

    private let genreChipsHolder = UIView()
    private let photoContainer = UIView()
    private let artistImageView = UIImageView()
    private let nameLabel = UILabel()
    private let genreLabel = UILabel()
    private let statsLabel = UILabel()
    private let bioLabel = UILabel()
    private let readMoreButton = UIButton(type: .system)
    private var bioExpanded = false
    private var showsFallbackImage = false
    private var genreChipsShown = false

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
        let stationRow = buildStationRow()
        genreChipsHolder.isHidden = true

        let mainStack = UIStackView(arrangedSubviews: [photoContainer, nameLabel, genreLabel, statsLabel, genreChipsHolder, actionRow, stationRow, bioStack])
        mainStack.axis = .vertical
        mainStack.spacing = 8
        mainStack.setCustomSpacing(16, after: photoContainer)
        mainStack.setCustomSpacing(4, after: nameLabel)
        mainStack.setCustomSpacing(4, after: genreLabel)
        mainStack.setCustomSpacing(14, after: statsLabel)
        mainStack.setCustomSpacing(16, after: genreChipsHolder)
        mainStack.setCustomSpacing(10, after: actionRow)
        mainStack.setCustomSpacing(20, after: stationRow)
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mainStack)

        let bioStackWidth = bioStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        bioStackWidth.priority = .defaultHigh
        let actionRowWidth = actionRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        actionRowWidth.priority = .defaultHigh
        let stationRowWidth = stationRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        stationRowWidth.priority = .defaultHigh
        let chipsWidth = genreChipsHolder.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        chipsWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            photoContainer.widthAnchor.constraint(equalToConstant: Self.imageSize),
            photoContainer.heightAnchor.constraint(equalToConstant: Self.imageSize),
            bioStackWidth,
            actionRowWidth,
            stationRowWidth,
            chipsWidth,
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

    /// A full-width glass capsule seeding a library radio station from this
    /// artist, the signature local-discovery entry point.
    private func buildStationRow() -> UIView {
        let station = LiquidGlass.actionCapsule(title: "Start Station", systemImage: "dot.radiowaves.left.and.right") { [weak self] in
            self?.onStartStation?()
        }
        station.accessibilityHint = "Plays a station of similar music from your library"
        let row = UIStackView(arrangedSubviews: [station])
        row.axis = .horizontal
        row.distribution = .fill
        return LiquidGlass.grouping(row)
    }

    private func applyGenreChips(_ genres: [String]) {
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
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: albumTitle, artist: info.name) { [weak self] image in
            guard let self, let image, self.showsFallbackImage else { return }
            self.artistImageView.contentMode = .scaleAspectFill
            self.artistImageView.image = image
        }
    }
}

/// A Last.fm popular-track row showing global rank, title, an owned checkmark
/// when the track exists in the local library, and its scrobble count.
final class PopularTrackCell: UICollectionViewCell {

    private let rankLabel = UILabel()
    private let ownedBadge = UIImageView()
    private let titleLabel = UILabel()
    private let playCountLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        rankLabel.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 15, weight: .regular), maximumPointSize: 24)
        rankLabel.adjustsFontForContentSizeCategory = true
        rankLabel.textColor = .white.withAlphaComponent(0.45)
        rankLabel.textAlignment = .center
        rankLabel.setContentHuggingPriority(.required, for: .horizontal)

        ownedBadge.image = UIImage(
            systemName: "checkmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        )
        ownedBadge.tintColor = .systemGreen
        ownedBadge.contentMode = .center
        ownedBadge.setContentHuggingPriority(.required, for: .horizontal)
        ownedBadge.isAccessibilityElement = false

        titleLabel.font = .scaled(.body, size: 16, weight: .regular)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        playCountLabel.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .regular), maximumPointSize: 22)
        playCountLabel.adjustsFontForContentSizeCategory = true
        playCountLabel.textColor = .white.withAlphaComponent(0.4)
        playCountLabel.textAlignment = .right
        playCountLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [rankLabel, ownedBadge, titleLabel, playCountLabel])
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            rankLabel.widthAnchor.constraint(equalToConstant: 24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with item: PopularTrackItem) {
        rankLabel.text = item.rank > 0 ? "\(item.rank)" : "\u{2013}"
        titleLabel.text = item.name
        let owned = item.ownedTrack != nil
        ownedBadge.isHidden = !owned
        titleLabel.textColor = owned ? .white : .white.withAlphaComponent(0.75)

        if item.playCount > 0 {
            playCountLabel.text = Self.abbreviated(item.playCount)
            playCountLabel.isHidden = false
        } else {
            playCountLabel.isHidden = true
        }

        isAccessibilityElement = true
        accessibilityLabel = item.name
        accessibilityValue = owned
            ? "In your library. Double tap to play from here through the rest of popular tracks."
            : "Not in your library"
        accessibilityTraits = owned ? .button : .staticText
    }

    private static func abbreviated(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM plays", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.0fK plays", Double(count) / 1_000)
        }
        return "\(count) plays"
    }
}

/// A loading or empty-state cell for the enrichment sections, with a spinner
/// while data is in flight and a dimmed message once it settles.
final class DetailMessageCell: UICollectionViewCell {

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        spinner.color = .white.withAlphaComponent(0.6)
        spinner.hidesWhenStopped = true

        label.font = .scaled(.subheadline, size: 14, weight: .regular)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white.withAlphaComponent(0.5)
        label.numberOfLines = 0
        label.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with item: DetailMessageItem) {
        label.text = item.text
        if item.isLoading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        isAccessibilityElement = true
        accessibilityLabel = item.text
    }
}
