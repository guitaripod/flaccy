import Combine
import UIKit
import UniformTypeIdentifiers

final class LibraryViewController: UIViewController, SonglinkShareable {

    private let viewModel = LibraryViewModel()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, LibraryItem>!
    private let segmentedControl = UISegmentedControl(items: ["Albums", "Songs", "Artists", "Playlists"])
    private var cancellables = Set<AnyCancellable>()
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let sectionIndexView = SectionIndexView()
    private let filterChipsView = FilterChipsView()
    private var chipsHeightConstraint: NSLayoutConstraint!
    private var lastRenderedFilter: LibraryFilter?
    private var lastRenderedLayout: LibraryLayoutMode?
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let loadingOverlay = UIView()
    private let loadingIconView = UIImageView()
    private let loadingLabel = UILabel()
    private let emptyStateIconView = UIImageView(image: UIImage(systemName: "music.note.list"))
    private let emptyStateLabel = UILabel()
    private var lastRenderedSegment: LibraryViewModel.Segment?
    private lazy var sampleMusicButton: UIButton = {
        var config = UIButton.Configuration.borderedProminent()
        config.title = "Add Sample Music"
        config.subtitle = "Bach, lossless, free"
        config.image = UIImage(systemName: "arrow.down.circle")
        config.imagePadding = 8
        config.cornerStyle = .large
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.downloadSampleMusic()
        })
        return button
    }()
    private lazy var emptyStateView: UIView = {
        let container = UIView()

        let imageView = emptyStateIconView
        imageView.tintColor = .tertiaryLabel
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 56, weight: .thin)
        imageView.contentMode = .scaleAspectFit

        let label = emptyStateLabel
        label.text = "Import files from Settings"
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [imageView, label, sampleMusicButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.setCustomSpacing(24, after: label)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -40),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -32),
        ])

        return container
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        setupLoadingOverlay()
        loadingOverlay.isHidden = false
        loadingOverlay.alpha = 1
        startLoadingPulse()
        navigationController?.setNavigationBarHidden(true, animated: false)

        setupSearchController()
        setupSegmentedControl()
        setupFilterChips()
        setupCollectionView()
        setupSectionIndex()
        configureDataSource()
        view.bringSubviewToFront(loadingOverlay)
        bindViewModel()
        updateRightBarButton(for: .albums)
        updateChips(for: .albums)

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            primaryAction: UIAction { [weak self] _ in self?.presentSettings() }
        )

        Task {
            await viewModel.loadLibrary()
            viewModel.restorePlaybackState()
        }

        observeWantlist()
    }

    private func observeWantlist() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(wantlistDidChange), name: WantlistService.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(wantlistDidResolve(_:)), name: WantlistService.didResolveItems, object: nil
        )
    }

    @objc private func wantlistDidChange() {
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(.wantlist) else { return }
        snapshot.reconfigureItems([.wantlist])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    @objc private func wantlistDidResolve(_ notification: Notification) {
        guard let names = notification.userInfo?["names"] as? [String], !names.isEmpty else { return }
        let summary = names.count == 1
            ? "Crossed off your Wantlist: \(names[0])"
            : "Crossed off your Wantlist: \(names[0]) and \(names.count - 1) more"
        ToastView.show(summary, in: view, style: .success)
        wantlistDidChange()
    }

    private func setupSearchController() {
        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Albums, Artists, Songs"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked
        navigationItem.largeTitleDisplayMode = .never
        definesPresentationContext = true
    }

    /// Hosts the segment picker as a full-width control pinned below the nav bar
    /// rather than as a width-constrained `titleView`, so all four titles render
    /// without truncation across device widths and Dynamic Type sizes.
    private func setupSegmentedControl() {
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.apportionsSegmentWidthsByContent = false
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        for state: UIControl.State in [.normal, .selected] {
            segmentedControl.setTitleTextAttributes(
                [.font: UIFont.scaled(.subheadline, size: 13, weight: .semibold)], for: state
            )
        }
        segmentedControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.impactLight.impactOccurred()
            let segment = LibraryViewModel.Segment(rawValue: self.segmentedControl.selectedSegmentIndex) ?? .albums
            self.viewModel.switchSegment(to: segment)
            self.updateRightBarButton(for: segment)
            self.updateChips(for: segment)
            self.updateSectionIndex()
        }, for: .valueChanged)
        view.addSubview(segmentedControl)
        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            segmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            segmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
    }

    private func updateRightBarButton(for segment: LibraryViewModel.Segment) {
        switch segment {
        case .albums:
            navigationItem.rightBarButtonItems = [
                UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), menu: albumSortMenu()),
                layoutToggleButton(),
            ]
        case .songs:
            let range = UIBarButtonItem(image: UIImage(systemName: "calendar"), menu: scrobbleRangeMenu())
            range.accessibilityLabel = "Play history range"
            navigationItem.rightBarButtonItems = [
                UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), menu: songSortMenu()),
                range,
                layoutToggleButton(),
            ]
        case .artists:
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "arrow.up.arrow.down"),
                menu: artistSortMenu()
            )
        case .playlists:
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.createPlaylistTapped() }
            )
        }
    }

    private func layoutToggleButton() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: viewModel.layoutMode.icon),
            primaryAction: UIAction { [weak self] _ in self?.toggleLayoutMode() }
        )
        item.accessibilityLabel = viewModel.layoutMode.accessibilityLabel
        return item
    }

    private func toggleLayoutMode() {
        selectionFeedback.selectionChanged()
        viewModel.cycleLayoutMode()
        updateRightBarButton(for: viewModel.currentSegment)
        applyLayoutAndSnapshot(crossfade: true)
    }

    /// Rebuilds the compositional layout for the current mode and reapplies the
    /// snapshot, optionally under a sub-350ms crossfade unless Reduce Motion is on.
    private func applyLayoutAndSnapshot(crossfade: Bool) {
        let segment = viewModel.currentSegment
        let snapshot = viewModel.currentSnapshot()
        let apply = {
            self.collectionView.setCollectionViewLayout(self.createLayout(for: segment), animated: false)
            self.dataSource.applySnapshotUsingReloadData(snapshot)
            self.updateEmptyState()
            self.updateSectionIndex()
        }
        if crossfade, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(
                with: collectionView, duration: 0.28,
                options: [.transitionCrossDissolve, .allowUserInteraction],
                animations: apply
            )
        } else {
            apply()
        }
    }

    private func albumSortMenu() -> UIMenu {
        let actions = LibraryViewModel.AlbumSort.allCases.map { sort in
            UIAction(
                title: sort.displayName,
                image: UIImage(systemName: sort.icon),
                state: viewModel.albumSort == sort ? .on : .off
            ) { [weak self] _ in
                self?.impactLight.impactOccurred()
                self?.viewModel.setAlbumSort(sort)
                self?.updateRightBarButton(for: .albums)
                self?.updateSectionIndex()
            }
        }
        return UIMenu(title: "Sort By", image: UIImage(systemName: "arrow.up.arrow.down"), children: actions)
    }

    private func songSortMenu() -> UIMenu {
        let actions = LibraryViewModel.SongSort.allCases
            .map { sort in
                UIAction(
                    title: sort.displayName,
                    image: UIImage(systemName: sort.icon),
                    state: viewModel.songSort == sort ? .on : .off
                ) { [weak self] _ in
                    self?.impactLight.impactOccurred()
                    self?.viewModel.setSongSort(sort)
                    self?.updateRightBarButton(for: .songs)
                    self?.updateSectionIndex()
                }
            }
        return UIMenu(title: "Sort By", image: UIImage(systemName: "arrow.up.arrow.down"), children: actions)
    }

    private func scrobbleRangeMenu() -> UIMenu {
        let actions = ChartPeriod.allCases.map { period in
            UIAction(
                title: period.displayName,
                state: viewModel.scrobbleRange == period ? .on : .off
            ) { [weak self] _ in
                self?.impactLight.impactOccurred()
                self?.viewModel.setScrobbleRange(period)
                self?.updateRightBarButton(for: .songs)
            }
        }
        return UIMenu(
            title: "Plays From",
            image: UIImage(systemName: "calendar"),
            children: actions
        )
    }

    private func artistSortMenu() -> UIMenu {
        let actions = LibraryViewModel.ArtistSort.allCases.map { sort in
            UIAction(
                title: sort.displayName,
                image: UIImage(systemName: sort.icon),
                state: viewModel.artistSort == sort ? .on : .off
            ) { [weak self] _ in
                self?.impactLight.impactOccurred()
                self?.viewModel.setArtistSort(sort)
                self?.updateRightBarButton(for: .artists)
                self?.updateSectionIndex()
            }
        }
        return UIMenu(title: "Sort By", image: UIImage(systemName: "arrow.up.arrow.down"), children: actions)
    }

    private func createPlaylistTapped() {
        impactLight.impactOccurred()
        let alert = UIAlertController(title: "New Playlist", message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Playlist name"
            textField.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { return }
            do {
                try DatabaseManager.shared.createPlaylist(name: name)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self?.viewModel.refreshPlaylists()
            } catch {
                AppLogger.error("Failed to create playlist: \(error.localizedDescription)", category: .database)
            }
        })
        present(alert, animated: true)
    }

    private func setupFilterChips() {
        filterChipsView.translatesAutoresizingMaskIntoConstraints = false
        filterChipsView.onSelect = { [weak self] filter in
            self?.viewModel.setFilter(filter)
        }
        view.addSubview(filterChipsView)
        chipsHeightConstraint = filterChipsView.heightAnchor.constraint(equalToConstant: 46)
        NSLayoutConstraint.activate([
            filterChipsView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
            filterChipsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filterChipsView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chipsHeightConstraint,
        ])
    }

    private func updateChips(for segment: LibraryViewModel.Segment) {
        let showsChips = segment == .albums || segment == .songs
        filterChipsView.isHidden = !showsChips
        chipsHeightConstraint.constant = showsChips ? 46 : 0
        guard showsChips else { return }
        filterChipsView.configure(filters: viewModel.availableFilters(), selected: viewModel.filter)
    }

    private func setupCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: createLayout(for: .albums))
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.backgroundColor = .clear

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: filterChipsView.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupSectionIndex() {
        sectionIndexView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sectionIndexView)

        NSLayoutConstraint.activate([
            sectionIndexView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            sectionIndexView.topAnchor.constraint(equalTo: filterChipsView.bottomAnchor, constant: 8),
            sectionIndexView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            sectionIndexView.widthAnchor.constraint(equalToConstant: 16),
        ])

        sectionIndexView.onSelectIndex = { [weak self] letter in
            guard let self,
                  let itemIndex = self.viewModel.indexOfFirstItem(forLetter: letter) else { return }
            let section = self.viewModel.currentSegment == .albums
                && self.dataSource.snapshot().numberOfSections > 1 ? 1 : 0
            guard section < self.collectionView.numberOfSections,
                  itemIndex < self.collectionView.numberOfItems(inSection: section) else { return }
            let indexPath = IndexPath(item: itemIndex, section: section)
            self.collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
        }
    }

    private func updateEmptyState() {
        switch viewModel.emptyState {
        case .none:
            collectionView.backgroundView = nil
        case .noLibrary:
            emptyStateIconView.image = UIImage(systemName: "music.note.list")
            emptyStateLabel.text = "Import files from Settings,\nor start with a free lossless album"
            sampleMusicButton.isHidden = false
            collectionView.backgroundView = emptyStateView
        case .noSearchResults(let query):
            emptyStateIconView.image = UIImage(systemName: "magnifyingglass")
            emptyStateLabel.text = "No results for \u{201C}\(query)\u{201D}"
            sampleMusicButton.isHidden = true
            collectionView.backgroundView = emptyStateView
        }
    }

    private func downloadSampleMusic() {
        guard !SampleMusicService.shared.isDownloading else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        var config = sampleMusicButton.configuration
        config?.showsActivityIndicator = true
        config?.title = "Downloading…"
        config?.subtitle = "About 130 MB of 24-bit FLAC"
        sampleMusicButton.configuration = config
        sampleMusicButton.isEnabled = false

        let progressObserver = NotificationCenter.default.addObserver(
            forName: SampleMusicService.progressDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            let text = SampleMusicService.shared.progressText
            guard !text.isEmpty else { return }
            var config = self?.sampleMusicButton.configuration
            config?.title = text
            self?.sampleMusicButton.configuration = config
        }

        Task { [weak self] in
            let success = await SampleMusicService.shared.downloadSamples()
            NotificationCenter.default.removeObserver(progressObserver)
            guard let self else { return }
            self.sampleMusicButton.isEnabled = true
            var config = self.sampleMusicButton.configuration
            config?.showsActivityIndicator = false
            config?.title = "Add Sample Music"
            config?.subtitle = "Bach, lossless, free"
            self.sampleMusicButton.configuration = config
            if success {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                ToastView.show("Sample album added — Open Goldberg Variations (CC0)", in: self.view, style: .success)
            } else {
                ToastView.show("Sample download failed — check your connection", in: self.view, style: .error)
            }
        }
    }

    private func updateSectionIndex() {
        let titles = viewModel.indexTitles()
        sectionIndexView.update(titles: titles)
        sectionIndexView.isHidden = titles.count < 5
            || viewModel.currentSegment == .playlists
            || viewModel.filter != .all
    }

    private func setupLoadingOverlay() {
        loadingOverlay.backgroundColor = .systemBackground
        loadingOverlay.isHidden = true
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingOverlay)

        loadingIconView.image = UIImage(systemName: "waveform.circle.fill")
        loadingIconView.tintColor = .tintColor
        loadingIconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 64, weight: .thin)
        loadingIconView.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.text = "flaccy"
        titleLabel.font = .scaled(.title1, size: 28, weight: .bold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [loadingIconView, titleLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(stack)

        NSLayoutConstraint.activate([
            loadingOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            loadingOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor, constant: -60),
        ])
    }

    private func startLoadingPulse() {
        loadingIconView.layer.removeAnimation(forKey: "pulse")
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 1.2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        loadingIconView.layer.add(pulse, forKey: "pulse")
    }

    private func stopLoadingPulse() {
        loadingIconView.layer.removeAnimation(forKey: "pulse")
    }

    private func badgeAccessories(qualityTrack: Track?, loved: Bool, scrobbleCount: Int? = nil) -> [UICellAccessory] {
        let container = UIStackView()
        container.axis = .horizontal
        container.spacing = 6
        container.alignment = .center

        if let scrobbleCount {
            container.addArrangedSubview(scrobbleCountView(scrobbleCount))
        }
        if loved {
            let heart = UIImageView(image: UIImage(
                systemName: "heart.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            ))
            heart.tintColor = .systemPink
            heart.accessibilityLabel = "Loved"
            heart.isAccessibilityElement = true
            container.addArrangedSubview(heart)
        }
        if qualityTrack?.qualityBadge != nil {
            let badge = QualityBadgeView(size: .compact)
            badge.configure(with: qualityTrack)
            container.addArrangedSubview(badge)
        }
        guard !container.arrangedSubviews.isEmpty else { return [] }
        let size = container.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        container.frame = CGRect(origin: .zero, size: size)
        return [.customView(configuration: .init(
            customView: container,
            placement: .trailing(),
            reservedLayoutWidth: .actual,
            maintainsFixedSize: true
        ))]
    }

    /// A compact play-count pill (waveform glyph + monospaced count) shown on song
    /// rows, sized so it never increases the row height set by the title/subtitle.
    private func scrobbleCountView(_ count: Int) -> UIView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 3
        stack.alignment = .center

        let glyph = UIImageView(image: UIImage(
            systemName: "waveform",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        ))
        glyph.tintColor = .tertiaryLabel

        let label = UILabel()
        label.text = count > 999 ? "\(count / 1000)k" : "\(count)"
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel

        stack.addArrangedSubview(glyph)
        stack.addArrangedSubview(label)
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = "\(count) scrobble\(count == 1 ? "" : "s")"
        return stack
    }

    private func configureArtworkRow(
        cell: ListArtworkCell, title: String, subtitle: String,
        albumTitle: String, artist: String, cornerRadius: CGFloat
    ) {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = title
        content.secondaryText = subtitle
        content.secondaryTextProperties.color = .secondaryLabel
        content.imageProperties.cornerRadius = cornerRadius
        content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
        if let cached = AlbumArtworkCache.shared.thumbnail(forAlbum: albumTitle, artist: artist) {
            content.image = cached
            cell.currentArtworkKey = nil
        } else {
            content.image = UIImage(systemName: "music.note")
            content.imageProperties.tintColor = .tertiaryLabel
            let artKey = "\(albumTitle)|\(artist)"
            cell.currentArtworkKey = artKey
            AlbumArtworkCache.shared.loadThumbnail(forAlbum: albumTitle, artist: artist) { [weak cell] image in
                guard let cell, cell.currentArtworkKey == artKey, let image,
                      var updated = cell.contentConfiguration as? UIListContentConfiguration else { return }
                updated.image = image
                updated.imageProperties.tintColor = nil
                cell.contentConfiguration = updated
            }
        }
        cell.contentConfiguration = content
    }

    private func configureDataSource() {
        let albumGridRegistration = UICollectionView.CellRegistration<AlbumCell, Album> { [weak self] cell, _, album in
            cell.configure(
                with: album,
                qualityTrack: self?.viewModel.representativeTrack(for: album),
                loved: self?.viewModel.isLovedAlbum(album) ?? false
            )
        }

        let albumListRegistration = UICollectionView.CellRegistration<ListArtworkCell, Album> { [weak self] cell, _, album in
            self?.configureArtworkRow(
                cell: cell, title: album.title, subtitle: album.artist,
                albumTitle: album.title, artist: album.artist, cornerRadius: 6
            )
            cell.accessories = self?.badgeAccessories(
                qualityTrack: self?.viewModel.representativeTrack(for: album),
                loved: self?.viewModel.isLovedAlbum(album) ?? false
            ) ?? []
        }

        let albumCompactRegistration = UICollectionView.CellRegistration<ListArtworkCell, Album> { [weak self] cell, _, album in
            var content = UIListContentConfiguration.valueCell()
            content.text = album.title
            content.secondaryText = album.artist
            content.secondaryTextProperties.color = .secondaryLabel
            content.textProperties.font = .scaled(.subheadline, size: 15, weight: .regular)
            cell.contentConfiguration = content
            cell.currentArtworkKey = nil
            cell.accessories = self?.badgeAccessories(
                qualityTrack: self?.viewModel.representativeTrack(for: album),
                loved: self?.viewModel.isLovedAlbum(album) ?? false
            ) ?? []
        }

        let songGridRegistration = UICollectionView.CellRegistration<TrackGridCell, Track> { cell, _, track in
            cell.configure(with: track, loved: LovedTracksService.shared.isLoved(track: track))
        }

        let songCompactRegistration = UICollectionView.CellRegistration<ListArtworkCell, Track> { [weak self] cell, _, track in
            var content = UIListContentConfiguration.valueCell()
            content.text = track.title
            content.secondaryText = track.artist
            content.secondaryTextProperties.color = .secondaryLabel
            content.textProperties.font = .scaled(.subheadline, size: 15, weight: .regular)
            cell.contentConfiguration = content
            cell.currentArtworkKey = nil
            cell.accessories = self?.badgeAccessories(
                qualityTrack: track, loved: LovedTracksService.shared.isLoved(track: track),
                scrobbleCount: self?.viewModel.scrobbleCount(for: track)
            ) ?? []
        }

        let artistRegistration = UICollectionView.CellRegistration<ListArtworkCell, ArtistItem> { [weak self] cell, _, artist in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = artist.name
            content.secondaryText = "\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s")"
            content.secondaryTextProperties.color = .secondaryLabel
            content.imageProperties.cornerRadius = 22
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)

            let firstAlbum = self?.viewModel.firstAlbum(forArtist: artist.name)
            let cachedArt: UIImage? = firstAlbum.flatMap { AlbumArtworkCache.shared.thumbnail(forAlbum: $0.title, artist: $0.artist) }

            if let cachedArt {
                content.image = cachedArt
                cell.currentArtworkKey = nil
            } else {
                content.image = UIImage(systemName: "person.crop.circle.fill")
                content.imageProperties.tintColor = .tertiaryLabel
                if let firstAlbum {
                    let artKey = "\(firstAlbum.title)|\(firstAlbum.artist)|\(artist.name)"
                    cell.currentArtworkKey = artKey
                    AlbumArtworkCache.shared.loadThumbnail(forAlbum: firstAlbum.title, artist: firstAlbum.artist) { [weak cell] image in
                        guard let cell, cell.currentArtworkKey == artKey, let image,
                              var updated = cell.contentConfiguration as? UIListContentConfiguration else { return }
                        updated.image = image
                        updated.imageProperties.tintColor = nil
                        cell.contentConfiguration = updated
                    }
                } else {
                    cell.currentArtworkKey = nil
                }
            }
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let playlistRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, PlaylistItem> { cell, _, playlist in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = playlist.name
            content.secondaryText = "\(playlist.trackCount) track\(playlist.trackCount == 1 ? "" : "s")"
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "music.note.list")
            content.imageProperties.tintColor = .tintColor
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let suggestedRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, SuggestedPlaylist> { cell, _, suggestion in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = suggestion.title
            content.secondaryText = "\(suggestion.subtitle) · \(suggestion.tracks.count) songs"
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: suggestion.systemImage)
            content.imageProperties.tintColor = .tintColor
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
            cell.contentConfiguration = content
            let play = UIImageView(image: UIImage(
                systemName: "play.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            ))
            play.tintColor = .tintColor
            cell.accessories = [.customView(configuration: .init(customView: play, placement: .trailing()))]
        }

        let chartsRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, _ in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = "Recap"
            content.secondaryText = "Your listening stats"
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "chart.bar.fill")
            content.imageProperties.tintColor = .systemPink
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let wantlistRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, _ in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = "Wantlist"
            let unseen = WantlistService.shared.unseenCount()
            content.secondaryText = unseen > 0
                ? "\(unseen) new suggestion\(unseen == 1 ? "" : "s")"
                : "Music to get & discoveries"
            content.secondaryTextProperties.color = unseen > 0 ? .systemTeal : .secondaryLabel
            content.image = UIImage(systemName: "sparkle.magnifyingglass")
            content.imageProperties.tintColor = .systemTeal
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { supplementaryView, _, _ in
            var config = UIListContentConfiguration.plainHeader()
            config.text = "Recently Played"
            config.textProperties.font = .scaled(.footnote, size: 13, weight: .semibold)
            config.textProperties.color = .secondaryLabel
            supplementaryView.contentConfiguration = config
        }

        let songRegistration = UICollectionView.CellRegistration<ListArtworkCell, Track> { [weak self] cell, _, track in
            self?.configureArtworkRow(
                cell: cell, title: track.title, subtitle: "\(track.artist) · \(track.albumTitle)",
                albumTitle: track.albumTitle, artist: track.artist, cornerRadius: 4
            )
            cell.accessories = self?.badgeAccessories(
                qualityTrack: track, loved: LovedTracksService.shared.isLoved(track: track),
                scrobbleCount: self?.viewModel.scrobbleCount(for: track)
            ) ?? []
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            [weak self] collectionView, indexPath, item in
            let mode = self?.viewModel.layoutMode ?? .grid
            switch item {
            case .recentAlbum(let album):
                return collectionView.dequeueConfiguredReusableCell(
                    using: albumGridRegistration, for: indexPath, item: album
                )
            case .album(let album):
                switch mode {
                case .grid:
                    return collectionView.dequeueConfiguredReusableCell(using: albumGridRegistration, for: indexPath, item: album)
                case .list:
                    return collectionView.dequeueConfiguredReusableCell(using: albumListRegistration, for: indexPath, item: album)
                case .compact:
                    return collectionView.dequeueConfiguredReusableCell(using: albumCompactRegistration, for: indexPath, item: album)
                }
            case .song(let track):
                switch mode {
                case .grid:
                    return collectionView.dequeueConfiguredReusableCell(using: songGridRegistration, for: indexPath, item: track)
                case .list:
                    return collectionView.dequeueConfiguredReusableCell(using: songRegistration, for: indexPath, item: track)
                case .compact:
                    return collectionView.dequeueConfiguredReusableCell(using: songCompactRegistration, for: indexPath, item: track)
                }
            case .artist(let artist):
                return collectionView.dequeueConfiguredReusableCell(
                    using: artistRegistration, for: indexPath, item: artist
                )
            case .playlist(let playlist):
                return collectionView.dequeueConfiguredReusableCell(
                    using: playlistRegistration, for: indexPath, item: playlist
                )
            case .suggestedPlaylist(let suggestion):
                return collectionView.dequeueConfiguredReusableCell(
                    using: suggestedRegistration, for: indexPath, item: suggestion
                )
            case .charts:
                return collectionView.dequeueConfiguredReusableCell(
                    using: chartsRegistration, for: indexPath, item: 0
                )
            case .wantlist:
                return collectionView.dequeueConfiguredReusableCell(
                    using: wantlistRegistration, for: indexPath, item: 0
                )
            }
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    private func bindViewModel() {
        viewModel.snapshotPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                let segment = self.viewModel.currentSegment
                let filter = self.viewModel.filter
                let segmentChanged = self.lastRenderedSegment != nil && self.lastRenderedSegment != segment
                let filterChanged = self.lastRenderedFilter != nil && self.lastRenderedFilter != filter
                self.lastRenderedSegment = segment
                self.lastRenderedFilter = filter
                self.lastRenderedLayout = self.viewModel.layoutMode
                let apply = {
                    self.collectionView.setCollectionViewLayout(
                        self.createLayout(for: segment), animated: false
                    )
                    self.dataSource.apply(snapshot, animatingDifferences: false)
                    self.updateEmptyState()
                    self.updateSectionIndex()
                    self.filterChipsView.setSelected(filter, animated: true)
                }
                if (segmentChanged || filterChanged), !UIAccessibility.isReduceMotionEnabled {
                    UIView.transition(
                        with: self.collectionView, duration: 0.24,
                        options: [.transitionCrossDissolve, .allowUserInteraction],
                        animations: apply
                    )
                } else {
                    apply()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: LovedTracksService.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleLovedChange() }
            .store(in: &cancellables)

        viewModel.loadingPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                guard let self else { return }
                if isLoading {
                    self.loadingOverlay.isHidden = false
                    self.loadingOverlay.alpha = 1
                    self.startLoadingPulse()
                } else {
                    self.stopLoadingPulse()
                    self.navigationController?.setNavigationBarHidden(false, animated: false)
                    UIView.animate(withDuration: 0.5, delay: 0.05, options: .curveEaseOut) {
                        self.loadingOverlay.alpha = 0
                    } completion: { _ in
                        self.loadingOverlay.isHidden = true
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Refreshes loved heart indicators when love state changes elsewhere. When
    /// the Favorites pivot is active, membership changes so the list is rebuilt;
    /// otherwise the visible rows are reconfigured in place.
    private func handleLovedChange() {
        if viewModel.filter == .favorites {
            viewModel.refilter()
            return
        }
        var snapshot = dataSource.snapshot()
        let affected = collectionView.indexPathsForVisibleItems
            .compactMap { dataSource.itemIdentifier(for: $0) }
            .filter {
                switch $0 {
                case .song, .album, .recentAlbum: return true
                default: return false
                }
            }
        guard !affected.isEmpty else { return }
        snapshot.reconfigureItems(affected)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Builds a leading swipe action that toggles the loved state of the song at
    /// the given index, with a heart-fill title, accent color, and haptic.
    private func loveSwipeConfiguration(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              case .song(let track) = item else { return nil }
        let loved = LovedTracksService.shared.isLoved(track: track)
        let action = UIContextualAction(
            style: .normal,
            title: loved ? "Unlove" : "Love"
        ) { _, _, completion in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task {
                await LovedTracksService.shared.toggleLove(track: track)
                await MainActor.run { completion(true) }
            }
        }
        action.image = UIImage(systemName: loved ? "heart.slash.fill" : "heart.fill")
        action.backgroundColor = .systemPink
        return UISwipeActionsConfiguration(actions: [action])
    }

    /// A cover-wall section of square art tiles at the given column count.
    private func gridSection(columns: Int, topInset: CGFloat) -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(columns)),
            heightDimension: .estimated(180)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(180))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: columns)
        group.interItemSpacing = .fixed(10)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 12
        section.contentInsets = NSDirectionalEdgeInsets(top: topInset, leading: 20, bottom: 24, trailing: 12)
        return section
    }

    private func listLayout(leadingInset: CGFloat, leadingSwipeLove: Bool) -> UICollectionViewCompositionalLayout {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.showsSeparators = true
        config.backgroundColor = .clear
        if leadingSwipeLove {
            config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.loveSwipeConfiguration(at: indexPath)
            }
        }
        return UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            section.contentInsets.leading = leadingInset
            return section
        }
    }

    private func createLayout(for segment: LibraryViewModel.Segment) -> UICollectionViewCompositionalLayout {
        switch segment {
        case .albums:
            switch viewModel.layoutMode {
            case .grid:
                return UICollectionViewCompositionalLayout { [weak self] sectionIndex, _ in
                    guard let self else { return nil }
                    let hasRecent = self.dataSource.snapshot().numberOfSections > 1
                    if sectionIndex == 0 && hasRecent {
                        let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(110), heightDimension: .estimated(160))
                        let item = NSCollectionLayoutItem(layoutSize: itemSize)
                        let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
                        let section = NSCollectionLayoutSection(group: group)
                        section.orthogonalScrollingBehavior = .continuous
                        section.interGroupSpacing = 10
                        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
                        return section
                    }
                    return self.gridSection(columns: 3, topInset: 12)
                }
            case .list:
                return listLayout(leadingInset: 20, leadingSwipeLove: false)
            case .compact:
                return listLayout(leadingInset: 20, leadingSwipeLove: false)
            }
        case .songs:
            switch viewModel.layoutMode {
            case .grid:
                return UICollectionViewCompositionalLayout { [weak self] _, _ in
                    self?.gridSection(columns: 3, topInset: 12)
                }
            case .list, .compact:
                return listLayout(leadingInset: 20, leadingSwipeLove: true)
            }
        case .artists:
            return listLayout(leadingInset: 20, leadingSwipeLove: false)
        case .playlists:
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.showsSeparators = true
            config.backgroundColor = .clear
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                guard let self,
                      let item = self.dataSource.itemIdentifier(for: indexPath),
                      case .playlist(let playlist) = item
                else { return nil }
                let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { _, _, completion in
                    do {
                        try DatabaseManager.shared.deletePlaylist(id: playlist.id)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        self.viewModel.refreshPlaylists()
                        completion(true)
                    } catch {
                        AppLogger.error("Failed to delete playlist: \(error.localizedDescription)", category: .database)
                        completion(false)
                    }
                }
                return UISwipeActionsConfiguration(actions: [deleteAction])
            }
            return UICollectionViewCompositionalLayout.list(using: config)
        }
    }

    private func presentSettings() {
        impactLight.impactOccurred()
        let settings = SettingsViewController()
        settings.onImportFiles = { [weak self] in
            self?.importTapped()
        }
        let nav = UINavigationController(rootViewController: settings)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    private func importTapped() {
        impactLight.impactOccurred()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio])
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    private func buildSongContextMenu(for track: Track) -> UIMenu {
        TrackContextMenu.build(
            for: track,
            in: self,
            push: { [weak self] viewController in
                self?.navigationController?.pushViewController(viewController, animated: true)
            }
        )
    }

    private func relativePath(for track: Track) -> String {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
        let trackPath = track.fileURL.standardizedFileURL.path
        guard trackPath.hasPrefix(docsDir.path) else { return track.fileURL.lastPathComponent }
        let rel = String(trackPath.dropFirst(docsDir.path.count))
        return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
    }

    private func buildSuggestedPlaylistMenu(for suggestion: SuggestedPlaylist) -> UIMenu {
        let tracks = suggestion.tracks
        let play = UIAction(title: "Play", image: UIImage(systemName: "play.fill")) { _ in
            AudioPlayer.shared.play(tracks, startingAt: 0)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        let shuffle = UIAction(title: "Shuffle", image: UIImage(systemName: "shuffle")) { _ in
            AudioPlayer.shared.play(tracks.shuffled(), startingAt: 0)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        let playNext = UIAction(title: "Play Next", image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { _ in
            for track in tracks.reversed() { AudioPlayer.shared.insertNext(track) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        let addToQueue = UIAction(title: "Add to Queue", image: UIImage(systemName: "text.append")) { _ in
            for track in tracks { AudioPlayer.shared.addToQueue(track) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        let save = UIAction(title: "Save as Playlist", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
            self?.saveSuggestion(suggestion)
        }
        let saveMenu = UIMenu(options: .displayInline, children: [save])
        return UIMenu(children: [play, shuffle, playNext, addToQueue, saveMenu])
    }

    private func saveSuggestion(_ suggestion: SuggestedPlaylist) {
        do {
            let playlist = try DatabaseManager.shared.createPlaylist(name: suggestion.title)
            if let id = playlist.id {
                for track in suggestion.tracks {
                    try DatabaseManager.shared.addTrackToPlaylist(playlistId: id, trackFileURL: relativePath(for: track))
                }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            viewModel.refreshPlaylists()
            ToastView.show("Saved \u{201C}\(suggestion.title)\u{201D}", in: view, style: .success)
        } catch {
            AppLogger.error("Failed to save suggested playlist: \(error.localizedDescription)", category: .database)
        }
    }
}

extension LibraryViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        impactLight.impactOccurred()

        switch item {
        case .album(let album), .recentAlbum(let album):
            let detail = AlbumDetailViewController(album: album)
            navigationController?.pushViewController(detail, animated: true)
        case .song(let track):
            let queue = viewModel.visibleSongs
            AudioPlayer.shared.play(queue, startingAt: queue.firstIndex(of: track) ?? 0)
        case .artist(let artist):
            let albums = viewModel.albumsForArtist(artist.name)
            let vc = ArtistDetailViewController(artistName: artist.name, albums: albums)
            navigationController?.pushViewController(vc, animated: true)
        case .playlist(let playlist):
            let vc = PlaylistDetailViewController(playlistId: playlist.id, playlistName: playlist.name)
            navigationController?.pushViewController(vc, animated: true)
        case .suggestedPlaylist(let suggestion):
            guard !suggestion.tracks.isEmpty else { return }
            AudioPlayer.shared.play(suggestion.tracks, startingAt: 0)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ToastView.show("Playing \(suggestion.title)", in: view, style: .success)
        case .charts:
            let vc = ChartsViewController()
            navigationController?.pushViewController(vc, animated: true)
        case .wantlist:
            let vc = WantlistViewController()
            navigationController?.pushViewController(vc, animated: true)
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let item = dataSource.itemIdentifier(for: indexPath) else { return nil }

        switch item {
        case .album(let album), .recentAlbum(let album):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                let playAction = UIAction(title: "Play", image: UIImage(systemName: "play.fill")) { _ in
                    AudioPlayer.shared.play(album.tracks, startingAt: 0)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                let shuffleAction = UIAction(title: "Shuffle", image: UIImage(systemName: "shuffle")) { _ in
                    var shuffled = album.tracks
                    shuffled.shuffle()
                    AudioPlayer.shared.play(shuffled, startingAt: 0)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                let playNextAction = UIAction(title: "Play Next", image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { _ in
                    for track in album.tracks.reversed() {
                        AudioPlayer.shared.insertNext(track)
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                let addToQueueAction = UIAction(title: "Add to Queue", image: UIImage(systemName: "text.append")) { _ in
                    for track in album.tracks {
                        AudioPlayer.shared.addToQueue(track)
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                let shareAlbum = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    guard let self else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    self.shareAlbumViaSonglink(title: album.title, artist: album.artist, from: self.view)
                }
                let shareMenu = UIMenu(options: .displayInline, children: [shareAlbum])
                let deleteAlbum = UIAction(title: "Delete from Library", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    guard let self else { return }
                    TrackContextMenu.confirmDelete(
                        title: "Delete \"\(album.title)\"?",
                        message: "All \(album.tracks.count) tracks will be removed from this device.",
                        in: self
                    ) { [weak self] in
                        Task { @MainActor in
                            await Library.shared.deleteTracks(album.tracks)
                            if let self {
                                ToastView.show("Deleted \(album.title)", in: self.view, style: .info)
                            }
                        }
                    }
                }
                let deleteMenu = UIMenu(options: .displayInline, children: [deleteAlbum])
                return UIMenu(children: [playAction, shuffleAction, playNextAction, addToQueueAction, shareMenu, deleteMenu])
            }
        case .song(let track):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                self?.buildSongContextMenu(for: track)
            }
        case .suggestedPlaylist(let suggestion):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                self?.buildSuggestedPlaylistMenu(for: suggestion)
            }
        default:
            return nil
        }
    }
}

extension LibraryViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            switch dataSource.itemIdentifier(for: indexPath) {
            case .album(let album), .recentAlbum(let album):
                AlbumArtworkCache.shared.preloadThumbnail(forAlbum: album.title, artist: album.artist)
            case .song(let track):
                AlbumArtworkCache.shared.preloadThumbnail(forAlbum: track.albumTitle, artist: track.artist)
            case .artist(let artist):
                if let album = viewModel.firstAlbum(forArtist: artist.name) {
                    AlbumArtworkCache.shared.preloadThumbnail(forAlbum: album.title, artist: album.artist)
                }
            default:
                break
            }
        }
    }
}

extension LibraryViewController: UISearchResultsUpdating {

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        viewModel.search(query: query)
    }
}

extension LibraryViewController: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { await viewModel.importFiles(from: urls) }
    }
}


final class ListArtworkCell: UICollectionViewListCell {
    var currentArtworkKey: String?

    override func prepareForReuse() {
        super.prepareForReuse()
        currentArtworkKey = nil
    }
}
