import Combine
import MidgarCore
import UIKit

/// The Recap dashboard: a scrolling, shareable surface of the listener's local
/// stats — profile, period selector, top artists/albums/tracks, a listening
/// clock, a streak heatmap, and a persona card — in flaccy's dark glass language.
final class ChartsViewController: UIViewController, SonglinkShareable {

    private let viewModel: ChartsViewModel
    private let audioPlayer: AudioPlaying

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<RecapSection, RecapItem>!
    private let backdrop = AmbientPaletteBackdropView()
    private let emptyLabel = UILabel()
    private let skeleton = RecapSkeletonView()
    private var wantsSkeletonOnLoad = true

    private var currentPalette = ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy")
    private var currentTint = UIColor.systemIndigo
    private var syncStatus: ListenHistoryStatus = .notConnected
    private var playQueues: [RecapSection: [Track]] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var renderGeneration = 0
    private var prewarmTasks: [Task<Void, Never>] = []

    private static let firstPaintBudget: Duration = .milliseconds(350)

    nonisolated private struct ArtworkPrewarmTarget: Sendable {
        let title: String
        let artist: String
        let remoteURL: String?
        let fallback: RecapArtworkQuery?
    }

    /// Everything a render takes from the library, worked out off the main thread.
    nonisolated private struct RenderPlan: Sendable {
        let artists: [RecapArtistItem]
        let albums: [AlbumItem]
        let tracks: [TrackItem]
        let heatmapDays: [HeatmapDay]
        let playQueues: [RecapSection: [Track]]
        let ownedArtwork: [ArtworkPrewarmTarget]
        let remoteArtwork: [ArtworkPrewarmTarget]
    }

    init(audioPlayer: AudioPlaying = AudioPlayer.shared) {
        self.audioPlayer = audioPlayer
        self.viewModel = ChartsViewModel()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Recap")
        view.backgroundColor = .black
        navigationItem.largeTitleDisplayMode = .never

        setupBackdrop()
        setupCollectionView()
        setupDataSource()
        setupOverlays()
        setupShareButton()
        bindViewModel()

        RecapLibraryIndexCache.shared.prepare()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        viewModel.setOnScreen(true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        viewModel.setOnScreen(false)
    }

    private func setupBackdrop() {
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.apply(currentPalette, animated: false)
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupCollectionView() {
        collectionView = FoldAwareCollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.contentInset.bottom = 24

        let refresh = UIRefreshControl()
        refresh.tintColor = .white
        refresh.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.viewModel.load(period: self.viewModel.selectedPeriod)
            self.collectionView.refreshControl?.endRefreshing()
        }, for: .valueChanged)
        collectionView.refreshControl = refresh

        collectionView.register(ProfileCell.self, forCellWithReuseIdentifier: ProfileCell.reuseID)
        collectionView.register(SyncBannerCell.self, forCellWithReuseIdentifier: SyncBannerCell.reuseID)
        collectionView.register(PeriodSelectorCell.self, forCellWithReuseIdentifier: PeriodSelectorCell.reuseID)
        collectionView.register(ArtistCardCell.self, forCellWithReuseIdentifier: ArtistCardCell.reuseID)
        collectionView.register(AlbumCoverCell.self, forCellWithReuseIdentifier: AlbumCoverCell.reuseID)
        collectionView.register(TrackRowCell.self, forCellWithReuseIdentifier: TrackRowCell.reuseID)
        collectionView.register(ClockCell.self, forCellWithReuseIdentifier: ClockCell.reuseID)
        collectionView.register(StreakCell.self, forCellWithReuseIdentifier: StreakCell.reuseID)
        collectionView.register(PersonaCell.self, forCellWithReuseIdentifier: PersonaCell.reuseID)
        collectionView.register(
            RecapHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: RecapHeaderView.reuseID
        )

        view.addSubview(collectionView)
        setContentScrollView(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupOverlays() {
        emptyLabel.text = String(localized: "No listening history yet.\nPlay something to build your Recap.")
        emptyLabel.font = .scaled(.body, size: 16, weight: .medium)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        skeleton.translatesAutoresizingMaskIntoConstraints = false
        skeleton.isHidden = true
        view.addSubview(skeleton)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            skeleton.topAnchor.constraint(equalTo: view.topAnchor),
            skeleton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            skeleton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupShareButton() {
        let share = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"),
            primaryAction: UIAction { [weak self] _ in self?.shareRecap() }
        )
        share.isEnabled = false
        share.accessibilityLabel = String(localized: "Share Recap")

        let yearInMusic = UIBarButtonItem(
            image: UIImage(systemName: "sparkles"),
            primaryAction: UIAction { [weak self] _ in self?.presentYearInMusic() }
        )
        yearInMusic.accessibilityLabel = String(localized: "Year in Music")

        navigationItem.rightBarButtonItems = [share, yearInMusic]
    }

    private func presentYearInMusic() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        present(YearInMusicViewController(), animated: true)
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, let section = self.dataSource.sectionIdentifier(for: index) else { return nil }
            return self.layoutSection(for: section, environment: environment)
        }
    }

    private func layoutSection(for section: RecapSection, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let full = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(120))
        let sideInset: CGFloat = 16

        let result: NSCollectionLayoutSection
        switch section {
        case .profile, .syncBanner, .persona:
            let item = NSCollectionLayoutItem(layoutSize: full)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: full, subitems: [item])
            result = NSCollectionLayoutSection(group: group)
        case .period:
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(44))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            result = NSCollectionLayoutSection(group: group)
        case .artists:
            let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(96), heightDimension: .estimated(150))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
            let s = NSCollectionLayoutSection(group: group)
            s.interGroupSpacing = 14
            s.orthogonalScrollingBehavior = .continuous
            result = s
        case .albums:
            if let grid = (collectionView as? FoldAwareCollectionView)?.foldGrid(leading: sideInset + 5, trailing: sideInset + 5) {
                return withHeader(.foldGrid(
                    grid, spacing: 10, rowSpacing: 12, height: .estimated(150),
                    insets: NSDirectionalEdgeInsets(top: 4, leading: sideInset + 5, bottom: 12, trailing: sideInset + 5)
                ), for: section)
            }
            let columns = AdaptiveLayout.gridColumns(forWidth: environment.container.effectiveContentSize.width)
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / CGFloat(columns)), heightDimension: .estimated(150))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 5, bottom: 12, trailing: 5)
            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(150))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: columns)
            result = NSCollectionLayoutSection(group: group)
        case .tracks:
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(52))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
            result = NSCollectionLayoutSection(group: group)
        case .clock:
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(260))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            result = NSCollectionLayoutSection(group: group)
        case .streak:
            let item = NSCollectionLayoutItem(layoutSize: full)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: full, subitems: [item])
            result = NSCollectionLayoutSection(group: group)
        }

        let trailing = section == .period
            ? (collectionView as? FoldAwareCollectionView)?.leadingPageTrailingInset(leading: sideInset, trailing: sideInset) ?? sideInset
            : sideInset
        result.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: sideInset, bottom: 12, trailing: trailing)
        return withHeader(result, for: section)
    }

    private func withHeader(_ result: NSCollectionLayoutSection, for section: RecapSection) -> NSCollectionLayoutSection {
        if section.headerTitle != nil {
            let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(34))
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            result.boundarySupplementaryItems = [header]
        }
        return result
    }

    private func setupDataSource() {
        dataSource = UICollectionViewDiffableDataSource<RecapSection, RecapItem>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, item in
            self?.cell(for: item, at: indexPath, in: collectionView)
        }

        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard kind == UICollectionView.elementKindSectionHeader,
                  let section = self?.dataSource.sectionIdentifier(for: indexPath.section),
                  let title = section.headerTitle else { return nil }
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: RecapHeaderView.reuseID,
                for: indexPath
            ) as! RecapHeaderView
            self?.configure(header, title: title, section: section)
            return header
        }
    }

    private func configure(_ header: RecapHeaderView, title: String, section: RecapSection) {
        guard playQueues[section]?.isEmpty == false else {
            header.configure(title: title)
            return
        }
        header.configure(
            title: title,
            onPlay: { [weak self] in self?.playList(section, shuffled: false) },
            onShuffle: { [weak self] in self?.playList(section, shuffled: true) }
        )
    }

    private func refreshVisibleHeaders() {
        let kind = UICollectionView.elementKindSectionHeader
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard let header = collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? RecapHeaderView,
                  let section = dataSource.sectionIdentifier(for: indexPath.section),
                  let title = section.headerTitle else { continue }
            configure(header, title: title, section: section)
        }
    }

    private func cell(for item: RecapItem, at indexPath: IndexPath, in collectionView: UICollectionView) -> UICollectionViewCell {
        let tint = currentTint
        switch item {
        case .profile(let profile):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ProfileCell.reuseID, for: indexPath) as! ProfileCell
            cell.configure(profile)
            return cell
        case .syncBanner(let status):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SyncBannerCell.reuseID, for: indexPath) as! SyncBannerCell
            cell.configure(status: status)
            return cell
        case .period(let period):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PeriodSelectorCell.reuseID, for: indexPath) as! PeriodSelectorCell
            cell.configure(selected: period)
            cell.onSelect = { [weak self] selected in self?.periodSelected(selected) }
            return cell
        case .artist(let artist):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ArtistCardCell.reuseID, for: indexPath) as! ArtistCardCell
            cell.configure(artist, tint: tint)
            return cell
        case .album(let album):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: AlbumCoverCell.reuseID, for: indexPath) as! AlbumCoverCell
            cell.configure(album)
            return cell
        case .track(let track):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TrackRowCell.reuseID, for: indexPath) as! TrackRowCell
            cell.configure(track)
            return cell
        case .clock(let clock):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ClockCell.reuseID, for: indexPath) as! ClockCell
            cell.configure(clock, tint: tint)
            return cell
        case .streak(let streak):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: StreakCell.reuseID, for: indexPath) as! StreakCell
            cell.configure(streak, tint: tint)
            return cell
        case .persona(let persona):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PersonaCell.reuseID, for: indexPath) as! PersonaCell
            cell.configure(persona, palette: currentPalette)
            return cell
        }
    }

    private func bindViewModel() {
        viewModel.dataPublisher
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in self?.render(data) }
            .store(in: &cancellables)

        viewModel.loadingPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                guard let self else { return }
                if loading, self.viewModel.data == nil || self.wantsSkeletonOnLoad { self.showSkeleton() }
            }
            .store(in: &cancellables)

        viewModel.syncStatusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.syncStatus = status
                self.reapplySyncBanner()
            }
            .store(in: &cancellables)
    }

    private func showSkeleton() {
        skeleton.isHidden = false
        skeleton.alpha = 1
        skeleton.startAnimating()
        collectionView.alpha = 0
        emptyLabel.isHidden = true
    }

    private func hideSkeleton() {
        guard !skeleton.isHidden else { collectionView.alpha = 1; return }
        let finish = { [weak self] in
            self?.skeleton.isHidden = true
            self?.skeleton.stopAnimating()
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            skeleton.alpha = 0
            collectionView.alpha = 1
            finish()
            return
        }
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.skeleton.alpha = 0
            self.collectionView.alpha = 1
        } completion: { _ in finish() }
    }

    /// Renders a freshly-loaded snapshot. The main thread only recolors the
    /// backdrop: matching the chart against the library, the play queues and
    /// the heatmap are worked out off it, against the cached library index.
    /// The artwork for every top album/track is then prewarmed into the shared
    /// thumbnail cache, the library's own covers and Last.fm's side by side,
    /// and the content is published once the owned covers are in or
    /// `firstPaintBudget` runs out, whichever comes first, so they appear
    /// already in place while a slow Last.fm lookup never holds the skeleton;
    /// a cover still on its way fades in on its cell.
    private func render(_ data: RecapData) {
        renderGeneration += 1
        let generation = renderGeneration

        updatePalette(for: data)
        navigationItem.rightBarButtonItem?.isEnabled = data.hasContent

        Task { [weak self] in
            let index = await RecapLibraryIndexCache.shared.index()
            let plan = await Self.plan(for: data, index: index)
            guard let self, generation == self.renderGeneration else { return }
            self.prewarmTasks.forEach { $0.cancel() }
            let owned = Task.detached(priority: .userInitiated) { await Self.runPrewarm(plan.ownedArtwork, source: "owned") }
            let remote = Task.detached(priority: .userInitiated) { await Self.runPrewarm(plan.remoteArtwork, source: "Last.fm") }
            self.prewarmTasks = [owned, remote]
            await Self.waitForPrewarm(owned, atMost: Self.firstPaintBudget)
            guard generation == self.renderGeneration else { return }
            self.playQueues = plan.playQueues
            self.apply(self.buildSnapshot(data: data, plan: plan), for: data)
        }
    }

    @concurrent
    nonisolated private static func plan(for data: RecapData, index: RecapLibraryIndex) async -> RenderPlan {
        let started = DispatchTime.now().uptimeNanoseconds
        let artists = data.topArtists.map { resolveArtist($0, in: index) }
        let albums = data.topAlbums.map { resolveAlbum($0, in: index) }
        let tracks = data.topTracks.map { resolveTrack($0, in: index) }
        let artwork = prewarmTargets(artists: artists, albums: albums, tracks: tracks)
        let plan = RenderPlan(
            artists: artists,
            albums: albums,
            tracks: tracks,
            heatmapDays: data.heatmap.map { HeatmapDay(date: $0.key, count: $0.value) }.sorted { $0.date < $1.date },
            playQueues: [
                .artists: index.queue(forArtists: data.topArtists),
                .albums: index.queue(forAlbums: data.topAlbums),
                .tracks: index.queue(forTracks: data.topTracks),
            ],
            ownedArtwork: artwork.owned,
            remoteArtwork: artwork.remote
        )
        let milliseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        MidgarLog.debug(
            "Recap resolved \(tracks.filter(\.isLocal).count)/\(tracks.count) top tracks to local library in \(milliseconds) ms",
            category: .content
        )
        return plan
    }

    private func buildSnapshot(data: RecapData, plan: RenderPlan) -> NSDiffableDataSourceSnapshot<RecapSection, RecapItem> {
        var snapshot = NSDiffableDataSourceSnapshot<RecapSection, RecapItem>()

        let displayPlays = data.totalPlays > 0 ? data.totalPlays : (data.userInfo?.playcount ?? 0)
        let profile = ProfileItem(
            username: data.userInfo?.name ?? String(localized: "You"),
            sinceText: sinceText(for: data.userInfo),
            avatarURL: data.userInfo?.imageURL,
            totalPlays: displayPlays,
            totalMinutes: data.totalMinutes
        )
        snapshot.appendSections([.profile])
        snapshot.appendItems([.profile(profile)], toSection: .profile)

        if syncStatus.isBackfilling {
            snapshot.appendSections([.syncBanner])
            snapshot.appendItems([.syncBanner(syncStatus)], toSection: .syncBanner)
        }

        snapshot.appendSections([.period])
        snapshot.appendItems([.period(data.period)], toSection: .period)

        if !plan.artists.isEmpty {
            snapshot.appendSections([.artists])
            snapshot.appendItems(plan.artists.map { .artist($0) }, toSection: .artists)
        }
        if !plan.albums.isEmpty {
            snapshot.appendSections([.albums])
            snapshot.appendItems(plan.albums.map { .album($0) }, toSection: .albums)
        }
        if !plan.tracks.isEmpty {
            snapshot.appendSections([.tracks])
            snapshot.appendItems(plan.tracks.map { .track($0) }, toSection: .tracks)
        }
        if data.hasScrobbles {
            snapshot.appendSections([.clock])
            snapshot.appendItems([.clock(ClockItem(buckets: data.listeningClock, seed: paletteSeed(for: data)))], toSection: .clock)

            snapshot.appendSections([.streak])
            snapshot.appendItems(
                [.streak(StreakItem(streakDays: data.streak, days: plan.heatmapDays, seed: paletteSeed(for: data)))],
                toSection: .streak
            )

            snapshot.appendSections([.persona])
            snapshot.appendItems([.persona(PersonaItem(persona: data.persona, seed: paletteSeed(for: data)))], toSection: .persona)
        }
        return snapshot
    }

    private func apply(_ snapshot: NSDiffableDataSourceSnapshot<RecapSection, RecapItem>, for data: RecapData) {
        dataSource.apply(snapshot, animatingDifferences: false)
        refreshVisibleHeaders()

        wantsSkeletonOnLoad = false
        hideSkeleton()

        emptyLabel.isHidden = data.hasContent
        if !data.hasContent {
            emptyLabel.text = syncStatus == .notConnected
                ? String(localized: "Connect Last.fm in Settings, or play\nsomething to build your Recap.")
                : String(localized: "No listening history yet.\nPlay something to build your Recap.")
        }
    }

    /// Builds the prewarm work lists, mirroring exactly how each cell will request
    /// its artwork so the downloaded thumbnails land under the keys the cells read.
    /// Covers the library owns are kept apart from the rest: they decode from the
    /// database in a few milliseconds each and fill most of the first screen,
    /// while the others wait on Last.fm.
    nonisolated private static func prewarmTargets(
        artists: [RecapArtistItem],
        albums: [AlbumItem],
        tracks: [TrackItem]
    ) -> (owned: [ArtworkPrewarmTarget], remote: [ArtworkPrewarmTarget]) {
        var owned: [ArtworkPrewarmTarget] = []
        var remote: [ArtworkPrewarmTarget] = []
        for artist in artists {
            guard let title = artist.artworkTitle, let name = artist.artworkArtist else { continue }
            owned.append(ArtworkPrewarmTarget(title: title, artist: name, remoteURL: nil, fallback: nil))
        }
        for album in albums {
            let target = ArtworkPrewarmTarget(
                title: album.artworkTitle ?? album.name,
                artist: album.artworkArtist ?? album.artist,
                remoteURL: album.imageURL,
                fallback: album.isLocal ? nil : .album(artist: album.artist, album: album.name)
            )
            if album.isLocal { owned.append(target) } else { remote.append(target) }
        }
        for track in tracks {
            let target = ArtworkPrewarmTarget(
                title: track.artworkTitle ?? track.name,
                artist: track.artworkArtist ?? track.artist,
                remoteURL: nil,
                fallback: track.isLocal ? nil : .track(artist: track.artist, track: track.name)
            )
            if track.isLocal { owned.append(target) } else { remote.append(target) }
        }
        return (owned, remote)
    }

    /// Returns once `prewarm` has finished or `budget` has run out, whichever
    /// comes first, and leaves the prewarm running so the covers it is still
    /// fetching land in the cache for the cells that show them.
    private static func waitForPrewarm(_ prewarm: Task<Void, Never>, atMost budget: Duration) async {
        let gate = FirstOfGate()
        await withCheckedContinuation { continuation in
            gate.arm(continuation)
            Task {
                await prewarm.value
                gate.open()
            }
            Task {
                try? await Task.sleep(for: budget)
                gate.open()
            }
        }
    }

    nonisolated private static func runPrewarm(_ targets: [ArtworkPrewarmTarget], source: String) async {
        guard !targets.isEmpty else { return }
        let start = Date()
        var cached = 0
        await withTaskGroup(of: Bool.self) { group in
            let maxConcurrent = 6
            var index = 0
            while index < min(maxConcurrent, targets.count) {
                let target = targets[index]
                index += 1
                group.addTask { await prewarm(target) }
            }
            while let didCache = await group.next() {
                if didCache { cached += 1 }
                if index < targets.count, !Task.isCancelled {
                    let target = targets[index]
                    index += 1
                    group.addTask { await prewarm(target) }
                }
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        let outcome = Task.isCancelled ? "superseded after" : "in"
        MidgarLog.info(
            "Recap prewarm: \(cached)/\(targets.count) \(source) artworks cached \(outcome) \(String(format: "%.2f", elapsed))s",
            category: .content
        )
    }

    nonisolated private static func prewarm(_ target: ArtworkPrewarmTarget) async -> Bool {
        await AsyncImageView.prewarmAlbum(
            title: target.title,
            artist: target.artist,
            remoteURL: target.remoteURL,
            remoteFallback: target.fallback
        )
    }

    nonisolated private static func resolveArtist(_ artist: ChartArtist, in index: RecapLibraryIndex) -> RecapArtistItem {
        var item = RecapArtistItem(rank: artist.rank, name: artist.name, playCount: artist.playCount)
        if let album = index.representativeAlbum(forArtist: artist.name) {
            item.artworkTitle = album.title
            item.artworkArtist = album.artist
            item.isLocal = true
        }
        return item
    }

    nonisolated private static func resolveAlbum(_ album: ChartAlbum, in index: RecapLibraryIndex) -> AlbumItem {
        var item = AlbumItem(rank: album.rank, name: album.name, artist: album.artistName, playCount: album.playCount, imageURL: album.imageURL)
        if let local = index.album(name: album.name, artist: album.artistName) {
            item.artworkTitle = local.title
            item.artworkArtist = local.artist
            item.isLocal = true
            item.localAlbumID = local.id
        }
        return item
    }

    nonisolated private static func resolveTrack(_ track: ChartTrack, in index: RecapLibraryIndex) -> TrackItem {
        var item = TrackItem(rank: track.rank, name: track.name, artist: track.artistName, playCount: track.playCount)
        if let local = index.track(title: track.name, artist: track.artistName) {
            item.artworkTitle = local.albumTitle
            item.artworkArtist = local.artist
            item.isLocal = true
            item.localTrackID = local.fileURL
        }
        return item
    }

    private func reapplySyncBanner() {
        var snapshot = dataSource.snapshot()
        guard syncStatus.isBackfilling else {
            if snapshot.sectionIdentifiers.contains(.syncBanner) {
                snapshot.deleteSections([.syncBanner])
                dataSource.apply(snapshot, animatingDifferences: !UIAccessibility.isReduceMotionEnabled)
            }
            return
        }
        guard snapshot.sectionIdentifiers.contains(.syncBanner) else {
            if let data = viewModel.data { render(data) }
            return
        }
        let items = snapshot.itemIdentifiers(inSection: .syncBanner)
        snapshot.deleteItems(items)
        snapshot.appendItems([.syncBanner(syncStatus)], toSection: .syncBanner)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func periodSelected(_ period: ChartPeriod) {
        guard period != viewModel.selectedPeriod else { return }
        wantsSkeletonOnLoad = true
        viewModel.load(period: period)
    }

    private func shareRecap() {
        guard let data = viewModel.data, data.hasContent else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let image = RecapShareCardView.makeImage(data: data, palette: currentPalette)
        let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        activity.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(activity, animated: true)
    }

    private func accentTint() -> UIColor {
        let colors = currentPalette.colors
        let candidate = colors.max(by: { saturation(of: $0) < saturation(of: $1) }) ?? currentPalette.dominant
        return brighten(candidate)
    }

    private func saturation(of color: UIColor) -> CGFloat {
        var s: CGFloat = 0
        color.getHue(nil, saturation: &s, brightness: nil, alpha: nil)
        return s
    }

    private func brighten(_ color: UIColor) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return UIColor(hue: h, saturation: min(1, s + 0.1), brightness: max(b, 0.72), alpha: 1)
    }

    private func updatePalette(for data: RecapData) {
        let palette = ArtworkPaletteExtractor.fallbackPalette(seed: paletteSeed(for: data))
        currentPalette = palette
        currentTint = accentTint()
        backdrop.apply(palette, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func paletteSeed(for data: RecapData) -> String {
        (data.userInfo?.name ?? "flaccy") + "|" + data.persona + "|" + (data.topArtists.first?.name ?? "")
    }

    private func sinceText(for info: LastFMUserInfo?) -> String? {
        guard let info, info.registeredUts > 0 else { return nil }
        let year = Calendar.current.component(.year, from: Date(timeIntervalSince1970: TimeInterval(info.registeredUts)))
        return String(localized: "scrobbling since \(year)")
    }
}

extension ChartsViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .track(let track): playTrack(track)
        case .album(let album): playAlbum(album)
        case .artist(let artist): playArtist(artist)
        default: break
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let identifier = dataSource.itemIdentifier(for: indexPath) else { return nil }

        switch identifier {
        case .track(let item) where item.isLocal:
            guard let url = item.localTrackID,
                  let track = Library.shared.allTracks.first(where: { $0.fileURL == url }) else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return nil }
                return TrackContextMenu.build(
                    for: track,
                    in: self,
                    push: { [weak self] viewController in
                        self?.navigationController?.pushViewController(viewController, animated: true)
                    }
                )
            }
        case .track(let item):
            return wantlistAddMenu(kind: .track, title: item.name, artist: item.artist, imageURL: nil)
        case .album(let item) where !item.isLocal:
            return wantlistAddMenu(kind: .album, title: item.name, artist: item.artist, imageURL: item.imageURL)
        case .artist(let item) where !item.isLocal:
            return wantlistAddMenu(kind: .artist, title: "", artist: item.name, imageURL: nil)
        default:
            return nil
        }
    }

    private func wantlistAddMenu(kind: WantlistKind, title: String, artist: String, imageURL: String?) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: String(localized: "Add to Wantlist"), image: UIImage(systemName: "sparkle.magnifyingglass")) { _ in
                    WantlistService.shared.addManual(kind: kind, title: title, artist: artist, imageURL: imageURL)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    if let view = self?.view {
                        ToastView.show(String(localized: "Added to Wantlist"), in: view, style: .success)
                    }
                },
            ])
        }
    }

    private func playList(_ section: RecapSection, shuffled: Bool) {
        guard let queue = playQueues[section], !queue.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        MidgarLog.info("Recap play list: \(section.headerTitle ?? "") (\(queue.count) tracks, shuffled: \(shuffled))", category: .playback)
        audioPlayer.play(shuffled ? queue.shuffled() : queue, startingAt: 0)
    }

    private func playTrack(_ tapped: TrackItem) {
        guard tapped.isLocal, let tappedURL = tapped.localTrackID else { return }
        let snapshot = dataSource.snapshot()
        guard snapshot.sectionIdentifiers.contains(.tracks) else { return }

        let queue: [Track] = snapshot.itemIdentifiers(inSection: .tracks).compactMap { item in
            guard case .track(let t) = item, t.isLocal, let url = t.localTrackID else { return nil }
            return Library.shared.allTracks.first { $0.fileURL == url }
        }
        guard let startIndex = queue.firstIndex(where: { $0.fileURL == tappedURL }) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        MidgarLog.info("Recap play track: \(tapped.name)", category: .playback)
        audioPlayer.play(queue, startingAt: startIndex)
    }

    private func playAlbum(_ tapped: AlbumItem) {
        guard tapped.isLocal, let id = tapped.localAlbumID,
              let album = Library.shared.albums.first(where: { $0.id == id }),
              !album.tracks.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        MidgarLog.info("Recap play album: \(album.title)", category: .playback)
        audioPlayer.play(album.tracks, startingAt: 0)
    }

    private func playArtist(_ tapped: RecapArtistItem) {
        guard tapped.isLocal else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        MidgarLog.info("Recap start station: \(tapped.name)", category: .playback)
        audioPlayer.startStation(seedArtist: tapped.name)
    }
}

/// Resumes one waiting caller exactly once, on whichever of several events gets
/// there first; the later ones find it already open and do nothing.
private final class FirstOfGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
