import UIKit

nonisolated enum ArtistDetailSection: Int, CaseIterable, Sendable {
    case header
    case similarArtists
    case popularTracks
    case albums
    case appearsOn

    var title: String? {
        switch self {
        case .header: nil
        case .similarArtists: String(localized: "Similar Artists in Your Library")
        case .popularTracks: String(localized: "Popular Tracks")
        case .albums: String(localized: "Albums")
        case .appearsOn: String(localized: "Appears On")
        }
    }
}

final class ArtistDetailViewController: UIViewController, SonglinkShareable {

    enum AlbumSort: String, CaseIterable {
        case title, year, trackCount

        var displayName: String {
            switch self {
            case .title: String(localized: "Title")
            case .year: String(localized: "Year")
            case .trackCount: String(localized: "Track Count")
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

    let artistName: String
    var albums: [Album]
    /// Albums the artist plays on without being their credit, so a composer on
    /// a Various Artists soundtrack has a page with their work on it.
    var appearsOn: [Album]
    var albumSort: AlbumSort = AlbumSort(rawValue: UserDefaults.standard.string(forKey: "artistDetailAlbumSort") ?? "") ?? .title
    var bio: String?
    var artistPhoto: UIImage?
    var artistPhotoTask: Task<Void, Never>?
    var similarAlbums: [Album] = []
    var similarLoaded = false
    var popularTracks: [PopularTrackItem] = []
    var popularLoaded = false
    var genres: [String] = []
    var enrichmentTask: Task<Void, Never>?
    var collectionView: UICollectionView!
    var dataSource: UICollectionViewDiffableDataSource<ArtistDetailSection, ArtistDetailItem>!
    let backdropView = AmbientPaletteBackdropView()
    var hasAnimatedAppearance = false
    let impactLight = UIImpactFeedbackGenerator(style: .light)
    let impactMedium = UIImpactFeedbackGenerator(style: .medium)

    init(artistName: String, albums: [Album], appearsOn: [Album] = []) {
        self.artistName = artistName
        self.albums = albums
        self.appearsOn = appearsOn
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(artworkChanged), name: AlbumArtworkCache.didChangeNotification, object: nil
        )
    }

    /// Fetches similar-library artists, Last.fm popular tracks, and genre tags
    /// off-main, caching each, then folds them into their sections as they land.
    func loadEnrichment() {
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

    /// Every library track this artist is on: the albums credited to them in
    /// full, plus the individual tracks they perform on somebody else's record.
    ///
    /// Taking only credited albums would hand a composer on a compilation an
    /// empty queue while the library holds thirty-one of their tracks. Mirrors
    /// `Core::artist_tracks` in the Linux client.
    @objc func artworkChanged() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func ownedTracks() -> [Track] {
        let key = LibraryHygiene.artistKey(artistName)
        let tracks = albums.flatMap(\.tracks)
            + appearsOn.flatMap { $0.tracks.filter { LibraryHygiene.artistKey($0.artist) == key } }
        return HideDuplicateSongsSetting.uniquePool(tracks)
    }

    func ownedTracksByTitle() -> [String: Track] {
        var map: [String: Track] = [:]
        for track in ownedTracks() {
            let key = track.title.lowercased()
            if map[key] == nil { map[key] = track }
        }
        return map
    }

    func startStation() {
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

    func setupBackdrop() {
        backdropView.frame = view.bounds
        view.addSubview(backdropView)
        applyPalette(from: initialArtwork(), animated: false)
    }

    func initialArtwork() -> UIImage? {
        guard let album = albums.first else { return nil }
        return album.artwork ?? AlbumArtworkCache.shared.thumbnail(forAlbum: album.title, artist: album.artist)
    }

    func applyPalette(from image: UIImage?, animated: Bool) {
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
    func fetchArtistPhoto() {
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

    func setupSortMenu() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.up.arrow.down"),
            menu: buildSortMenu()
        )
    }

    func buildSortMenu() -> UIMenu {
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
        return UIMenu(title: String(localized: "Sort By"), children: actions)
    }

    func sortAlbums() {
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

    func fetchArtistInfo() {
        guard let artist = try? DatabaseManager.shared.fetchArtist(name: artistName) else { return }
        if let rawBio = artist.bio, !rawBio.isEmpty {
            bio = rawBio
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func setupCollectionView() {
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

    func createLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let section = self?.section(at: sectionIndex) else { return nil }

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
                layoutSection.contentInsetsReference = .safeArea
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
                layoutSection.contentInsetsReference = .safeArea
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
                layoutSection.contentInsetsReference = .safeArea
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20)
                layoutSection.boundarySupplementaryItems = [Self.sectionHeaderItem()]
                return layoutSection

            case .albums, .appearsOn:
                let columns = AdaptiveLayout.shelfColumns(forWidth: environment.container.effectiveContentSize.width)
                let itemSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0 / CGFloat(columns)),
                    heightDimension: .estimated(240)
                )
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                let groupSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .estimated(240)
                )
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: columns)
                group.interItemSpacing = .fixed(12)
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.interGroupSpacing = 16
                layoutSection.contentInsetsReference = .safeArea
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

    static func sectionHeaderItem() -> NSCollectionLayoutBoundarySupplementaryItem {
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

    func configureDataSource() {
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
        ) { [weak self] supplementaryView, _, indexPath in
            var config = UIListContentConfiguration.header()
            config.text = self?.section(at: indexPath.section)?.title
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

        dataSource.supplementaryViewProvider = { [weak self] collectionView, _, indexPath in
            guard let section = self?.section(at: indexPath.section), section.title != nil else { return nil }
            return collectionView.dequeueConfiguredReusableSupplementary(using: sectionHeaderRegistration, for: indexPath)
        }
    }

    func applySnapshot(animatingDifferences: Bool = false) {
        var snapshot = NSDiffableDataSourceSnapshot<ArtistDetailSection, ArtistDetailItem>()
        snapshot.appendSections(visibleSections())

        let totalTracks = ownedTracks().count
        let genre = (albums + appearsOn).compactMap(\.genre).first
        let firstAlbum = albums.first ?? appearsOn.first
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
        if !albums.isEmpty {
            snapshot.appendItems(albums.map { .album($0) }, toSection: .albums)
        }
        if !appearsOn.isEmpty {
            snapshot.appendItems(appearsOn.map { .album($0) }, toSection: .appearsOn)
        }
        dataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    /// The sections this artist actually has. An album grid is dropped rather
    /// than shown empty under its heading: a composer credited with no album of
    /// their own has only an Appears On shelf, and a solo artist has only the
    /// Albums one.
    func visibleSections() -> [ArtistDetailSection] {
        ArtistDetailSection.allCases.filter { section in
            switch section {
            case .albums: !albums.isEmpty
            case .appearsOn: !appearsOn.isEmpty
            case .header, .similarArtists, .popularTracks: true
            }
        }
    }

    /// The section shown at `index`, read from the snapshot rather than from
    /// the raw value — sections are dropped when empty, so position and case
    /// order no longer agree.
    func section(at index: Int) -> ArtistDetailSection? {
        dataSource?.sectionIdentifier(for: index) ?? ArtistDetailSection(rawValue: index)
    }

    func similarSectionItems() -> [ArtistDetailItem] {
        guard similarLoaded else {
            return [.message(DetailMessageItem(id: "similar.loading", text: String(localized: "Finding artists in your library\u{2026}"), isLoading: true))]
        }
        guard !similarAlbums.isEmpty else {
            return [.message(DetailMessageItem(id: "similar.empty", text: String(localized: "No similar artists in your library yet."), isLoading: false))]
        }
        return similarAlbums.map { .similarAlbum(SimilarAlbumItem(album: $0)) }
    }

    func popularSectionItems() -> [ArtistDetailItem] {
        guard popularLoaded else {
            return [.message(DetailMessageItem(id: "popular.loading", text: String(localized: "Loading popular tracks\u{2026}"), isLoading: true))]
        }
        guard !popularTracks.isEmpty else {
            return [.message(DetailMessageItem(id: "popular.empty", text: String(localized: "No popular tracks available."), isLoading: false))]
        }
        return popularTracks.map { .popularTrack($0) }
    }

    func playAll(shuffled: Bool) {
        var tracks = ownedTracks()
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
