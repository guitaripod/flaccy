import Combine
import UIKit

/// The Recap dashboard: a scrolling, shareable surface of the listener's local
/// stats — profile, period selector, top artists/albums/tracks, a listening
/// clock, a streak heatmap, and a persona card — in flaccy's dark glass language.
final class ChartsViewController: UIViewController {

    private let viewModel: ChartsViewModel
    private let audioPlayer: AudioPlaying

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<RecapSection, RecapItem>!
    private let backdrop = AmbientPaletteBackdropView()
    private let emptyLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    private var currentPalette = ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy")
    private var currentTint = UIColor.systemIndigo
    private var importState: RecapImportState = .available
    private var cancellables = Set<AnyCancellable>()

    init(audioPlayer: AudioPlaying = AudioPlayer.shared) {
        self.audioPlayer = audioPlayer
        self.viewModel = ChartsViewModel()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Recap"
        view.backgroundColor = .black
        navigationItem.largeTitleDisplayMode = .never

        setupBackdrop()
        setupCollectionView()
        setupDataSource()
        setupOverlays()
        setupShareButton()
        bindViewModel()

        viewModel.load(period: viewModel.selectedPeriod)
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
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
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
        collectionView.register(ImportBannerCell.self, forCellWithReuseIdentifier: ImportBannerCell.reuseID)
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
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupOverlays() {
        emptyLabel.text = "No listening history yet.\nPlay something, or import your\nLast.fm history above."
        emptyLabel.font = .scaled(.body, size: 16, weight: .medium)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func setupShareButton() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"),
            primaryAction: UIAction { [weak self] _ in self?.shareRecap() }
        )
        navigationItem.rightBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Share Recap"
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
        case .profile, .importBanner, .persona:
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
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / 3.0), heightDimension: .estimated(150))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            item.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 5, bottom: 12, trailing: 5)
            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(150))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item, item, item])
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

        result.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: sideInset, bottom: 12, trailing: sideInset)

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
            header.configure(title: title)
            return header
        }
    }

    private func cell(for item: RecapItem, at indexPath: IndexPath, in collectionView: UICollectionView) -> UICollectionViewCell {
        let tint = currentTint
        switch item {
        case .profile(let profile):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ProfileCell.reuseID, for: indexPath) as! ProfileCell
            cell.configure(profile)
            return cell
        case .importBanner(let state):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ImportBannerCell.reuseID, for: indexPath) as! ImportBannerCell
            cell.configure(state: state)
            cell.onTap = { [weak self] in self?.importTapped() }
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
                if loading, self.viewModel.data == nil { self.spinner.startAnimating() } else { self.spinner.stopAnimating() }
            }
            .store(in: &cancellables)

        viewModel.importStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.importState = state
                self.reapplyImportBanner()
            }
            .store(in: &cancellables)
    }

    private func render(_ data: RecapData) {
        updatePalette(for: data)
        navigationItem.rightBarButtonItem?.isEnabled = data.hasContent

        var snapshot = NSDiffableDataSourceSnapshot<RecapSection, RecapItem>()

        let displayPlays = data.totalPlays > 0 ? data.totalPlays : (data.userInfo?.playcount ?? 0)
        let profile = ProfileItem(
            username: data.userInfo?.name ?? "You",
            sinceText: sinceText(for: data.userInfo),
            avatarURL: data.userInfo?.imageURL,
            totalPlays: displayPlays,
            totalMinutes: data.totalMinutes
        )
        snapshot.appendSections([.profile])
        snapshot.appendItems([.profile(profile)], toSection: .profile)

        if importState != .done {
            snapshot.appendSections([.importBanner])
            snapshot.appendItems([.importBanner(importState)], toSection: .importBanner)
        }

        snapshot.appendSections([.period])
        snapshot.appendItems([.period(data.period)], toSection: .period)

        if !data.topArtists.isEmpty {
            snapshot.appendSections([.artists])
            snapshot.appendItems(data.topArtists.map { .artist(RecapArtistItem(rank: $0.rank, name: $0.name, playCount: $0.playCount)) }, toSection: .artists)
        }
        if !data.topAlbums.isEmpty {
            snapshot.appendSections([.albums])
            snapshot.appendItems(data.topAlbums.map { .album(AlbumItem(rank: $0.rank, name: $0.name, artist: $0.artistName, playCount: $0.playCount, imageURL: $0.imageURL)) }, toSection: .albums)
        }
        if !data.topTracks.isEmpty {
            snapshot.appendSections([.tracks])
            snapshot.appendItems(data.topTracks.map { .track(TrackItem(rank: $0.rank, name: $0.name, artist: $0.artistName, playCount: $0.playCount)) }, toSection: .tracks)
        }
        if data.hasScrobbles {
            snapshot.appendSections([.clock])
            snapshot.appendItems([.clock(ClockItem(buckets: data.listeningClock, seed: paletteSeed(for: data)))], toSection: .clock)

            snapshot.appendSections([.streak])
            let days = data.heatmap.map { HeatmapDay(date: $0.key, count: $0.value) }.sorted { $0.date < $1.date }
            snapshot.appendItems([.streak(StreakItem(streakDays: data.streak, days: days, seed: paletteSeed(for: data)))], toSection: .streak)

            snapshot.appendSections([.persona])
            snapshot.appendItems([.persona(PersonaItem(persona: data.persona, seed: paletteSeed(for: data)))], toSection: .persona)
        }

        dataSource.apply(snapshot, animatingDifferences: false)

        emptyLabel.isHidden = data.hasContent
        if !data.hasContent {
            emptyLabel.text = importState == .unavailable
                ? "Connect Last.fm in Settings, or play\nsomething to build your Recap."
                : "No listening history yet.\nPlay something, or import your\nLast.fm history above."
        }
    }

    private func reapplyImportBanner() {
        var snapshot = dataSource.snapshot()
        if importState == .done {
            if snapshot.sectionIdentifiers.contains(.importBanner) {
                snapshot.deleteSections([.importBanner])
                dataSource.apply(snapshot, animatingDifferences: !UIAccessibility.isReduceMotionEnabled)
            }
            return
        }
        guard snapshot.sectionIdentifiers.contains(.importBanner) else { return }
        let items = snapshot.itemIdentifiers(inSection: .importBanner)
        snapshot.deleteItems(items)
        snapshot.appendItems([.importBanner(importState)], toSection: .importBanner)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func periodSelected(_ period: ChartPeriod) {
        guard period != viewModel.selectedPeriod else { return }
        viewModel.load(period: period)
    }

    private func importTapped() {
        guard importState == .available else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        viewModel.importHistory()
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
        return "scrobbling since \(year)"
    }
}

extension ChartsViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
    }
}
