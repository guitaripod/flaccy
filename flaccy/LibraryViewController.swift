import Combine
import FlaccyCore
import UIKit
import UniformTypeIdentifiers

final class LibraryViewController: UIViewController, SonglinkShareable {

    private let viewModel = LibraryViewModel()
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, LibraryItem>!
    private let segmentedControl = IdentifiedSegmentedControl(
        items: [String(localized: "Albums"), String(localized: "Songs"), String(localized: "Artists"), String(localized: "Playlists")],
        identifiers: ["library.tab.albums", "library.tab.songs", "library.tab.artists", "library.tab.playlists"]
    )
    private var cancellables = Set<AnyCancellable>()
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let sectionIndexView = SectionIndexView()
    private let filterChipsView = FilterChipsView()
    private var chipsHeightConstraint: NSLayoutConstraint!
    private var lastRenderedFilter: LibraryFilter?
    private var lastRenderedLayout: LibraryLayoutMode?
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private var debutView: LibraryDebutView?
    private weak var debutSheet: LibraryDebutSheetController?
    private var renderedDebutAct: LibraryDebutAct?
    private var debutSummary: LibraryDebutSummary?
    private var fedMosaicKeys = Set<String>()
    private let statusBanner = LibraryStatusBanner()
    private var statusBannerHeight: NSLayoutConstraint!
    private let emptyStateIconView = UIImageView(image: UIImage(systemName: "music.note.list"))
    private let emptyStateLabel = UILabel()
    private var lastRenderedSegment: LibraryViewModel.Segment?
    private lazy var sampleMusicButton: UIButton = {
        var config = UIButton.Configuration.borderedProminent()
        config.title = String(localized: "Add Sample Music")
        config.subtitle = String(localized: "Bach, lossless, free")
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
        label.text = String(localized: "Import files from Settings")
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

        installDebutViewIfNeeded()

        setupSearchController()
        setupSegmentedControl()
        setupFilterChips()
        setupStatusBanner()
        setupCollectionView()
        setupSectionIndex()
        configureDataSource()
        if let debutView { view.bringSubviewToFront(debutView) }
        bindViewModel()
        updateRightBarButton(for: .albums)
        updateChips(for: .albums)

        let settingsItem = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            primaryAction: UIAction { [weak self] _ in self?.presentSettings() }
        )
        settingsItem.accessibilityIdentifier = "library.settings"
        navigationItem.leftBarButtonItem = settingsItem

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
            ? String(localized: "Crossed off your Wantlist: \(names[0])")
            : String(localized: "Crossed off your Wantlist: \(names[0]) and \(names.count - 1) more")
        ToastView.show(summary, in: view, style: .success)
        wantlistDidChange()
    }

    private func setupSearchController() {
        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = String(localized: "Albums, Artists, Songs")
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
                sortButton(menu: albumSortMenu()),
                layoutToggleButton(),
            ]
        case .songs:
            let range = UIBarButtonItem(image: UIImage(systemName: "calendar"), menu: scrobbleRangeMenu())
            range.accessibilityLabel = String(localized: "Play history range")
            navigationItem.rightBarButtonItems = [
                sortButton(menu: songSortMenu()),
                range,
                layoutToggleButton(),
            ]
        case .artists:
            navigationItem.rightBarButtonItem = sortButton(menu: artistSortMenu())
        case .playlists:
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.createPlaylistTapped() }
            )
        }
    }

    private func sortButton(menu: UIMenu) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), menu: menu)
        item.accessibilityIdentifier = "library.sort"
        return item
    }

    private func layoutToggleButton() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: viewModel.layoutMode.icon),
            primaryAction: UIAction { [weak self] _ in self?.toggleLayoutMode() }
        )
        item.accessibilityLabel = viewModel.layoutMode.accessibilityLabel
        item.accessibilityIdentifier = viewModel.layoutMode.accessibilityIdentifier
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
        let layout = viewModel.layoutMode
        let snapshot = viewModel.currentSnapshot()
        let apply = { [weak self] in
            guard let self else { return }
            self.applyLibrarySnapshot(
                snapshot,
                segment: segment,
                layout: layout,
                forceLayout: true,
                useReload: true
            )
        }
        if crossfade, !UIAccessibility.isReduceMotionEnabled, snapshot.numberOfItems < 80 {
            UIView.transition(
                with: collectionView, duration: 0.2,
                options: [.transitionCrossDissolve, .allowUserInteraction],
                animations: apply
            )
        } else {
            apply()
        }
    }

    /// Applies a library snapshot with the cheapest path available: only rebuild
    /// the compositional layout when segment/layout mode change, and use
    /// reload-data (skip O(n) diff) when swapping entire lists.
    private func applyLibrarySnapshot(
        _ snapshot: LibraryViewModel.Snapshot,
        segment: LibraryViewModel.Segment,
        layout: LibraryLayoutMode,
        forceLayout: Bool,
        useReload: Bool
    ) {
        let needsLayout = forceLayout
            || lastRenderedSegment != segment
            || lastRenderedLayout != layout
        if needsLayout {
            collectionView.setCollectionViewLayout(createLayout(for: segment), animated: false)
            lastRenderedLayout = layout
        }
        if useReload {
            dataSource.applySnapshotUsingReloadData(snapshot)
        } else {
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        updateEmptyState()
        updateSectionIndex()
    }

    private func albumSortMenu() -> UIMenu {
        let actions = LibraryViewModel.AlbumSort.allCases.map { sort -> UIAction in
            let action = UIAction(
                title: sort.displayName,
                image: UIImage(systemName: sort.icon),
                state: viewModel.albumSort == sort ? .on : .off
            ) { [weak self] _ in
                self?.impactLight.impactOccurred()
                self?.viewModel.setAlbumSort(sort)
                self?.updateRightBarButton(for: .albums)
                self?.updateSectionIndex()
                self?.scrollToTopForSortChange()
            }
            action.accessibilityIdentifier = "sort.option.\(sort.rawValue)"
            return action
        }
        return UIMenu(title: String(localized: "Sort By"), image: UIImage(systemName: "arrow.up.arrow.down"), children: actions)
    }

    private func songSortMenu() -> UIMenu {
        let actions = LibraryViewModel.SongSort.allCases
            .map { sort -> UIAction in
                let action = UIAction(
                    title: sort.displayName,
                    image: UIImage(systemName: sort.icon),
                    state: viewModel.songSort == sort ? .on : .off
                ) { [weak self] _ in
                    self?.impactLight.impactOccurred()
                    self?.viewModel.setSongSort(sort)
                    self?.updateRightBarButton(for: .songs)
                    self?.updateSectionIndex()
                    self?.scrollToTopForSortChange()
                }
                action.accessibilityIdentifier = "sort.option.\(sort.rawValue)"
                return action
            }
        return UIMenu(title: String(localized: "Sort By"), image: UIImage(systemName: "arrow.up.arrow.down"), children: actions)
    }

    private func scrollToTopForSortChange() {
        collectionView.setContentOffset(
            CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
            animated: false
        )
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
            title: String(localized: "Plays From"),
            image: UIImage(systemName: "calendar"),
            children: actions
        )
    }

    private func artistSortMenu() -> UIMenu {
        let actions = LibraryViewModel.ArtistSort.allCases.map { sort -> UIAction in
            let action = UIAction(
                title: sort.displayName,
                image: UIImage(systemName: sort.icon),
                state: viewModel.artistSort == sort ? .on : .off
            ) { [weak self] _ in
                self?.impactLight.impactOccurred()
                self?.viewModel.setArtistSort(sort)
                self?.updateRightBarButton(for: .artists)
                self?.updateSectionIndex()
                self?.scrollToTopForSortChange()
            }
            action.accessibilityIdentifier = "sort.option.\(sort.rawValue)"
            return action
        }
        return UIMenu(title: String(localized: "Sort By"), image: UIImage(systemName: "arrow.up.arrow.down"), children: actions)
    }

    private func createPlaylistTapped() {
        impactLight.impactOccurred()
        let alert = UIAlertController(title: String(localized: "New Playlist"), message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = String(localized: "Playlist name")
            textField.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Create"), style: .default) { [weak self] _ in
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
            self?.updateSectionIndex()
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
        collectionView.keyboardDismissMode = .onDrag

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: statusBanner.bottomAnchor),
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
            sectionIndexView.topAnchor.constraint(equalTo: statusBanner.bottomAnchor, constant: 8),
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
            emptyStateLabel.text = String(localized: "Import files from Settings,\nor start with a free lossless album")
            sampleMusicButton.isHidden = false
            collectionView.backgroundView = emptyStateView
        case .noSearchResults(let query):
            emptyStateIconView.image = UIImage(systemName: "magnifyingglass")
            emptyStateLabel.text = String(localized: "No results for \u{201C}\(query)\u{201D}")
            sampleMusicButton.isHidden = true
            collectionView.backgroundView = emptyStateView
        }
    }

    private func downloadSampleMusic() {
        guard !SampleMusicService.shared.isDownloading else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        var config = sampleMusicButton.configuration
        config?.showsActivityIndicator = true
        config?.title = String(localized: "Downloading…")
        config?.subtitle = String(localized: "About 130 MB of 24-bit FLAC")
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
            config?.title = String(localized: "Add Sample Music")
            config?.subtitle = String(localized: "Bach, lossless, free")
            self.sampleMusicButton.configuration = config
            if success {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                ToastView.show(String(localized: "Sample album added — Open Goldberg Variations (CC0)"), in: self.view, style: .success)
            } else {
                ToastView.show(String(localized: "Sample download failed — check your connection"), in: self.view, style: .error)
            }
        }
    }

    private func updateSectionIndex() {
        let shouldShow = viewModel.currentSegment != .playlists
            && viewModel.filter == .all
            && viewModel.isCurrentSortAlphabetical
        let titles = shouldShow ? viewModel.indexTitles() : []
        sectionIndexView.update(titles: titles)
        sectionIndexView.isHidden = !shouldShow || titles.count < 5
        if !sectionIndexView.isHidden {
            view.bringSubviewToFront(sectionIndexView)
        }
    }

    /// Adds the Debut only when no earlier launch ever indexed a library.
    ///
    /// The question is answered from `UserDefaults` rather than the database,
    /// because by the time a `SELECT` could answer it the first frame is already
    /// on screen — which is how a relaunch used to get a 1% ring it then had to
    /// crossfade away. A returning library never puts the view in the hierarchy
    /// at all, so there is nothing to flash.
    private func installDebutViewIfNeeded() {
        guard !LibraryStartupProbe.hadIndexedLibrary else { return }
        let debut = LibraryDebutView()
        debut.translatesAutoresizingMaskIntoConstraints = false
        debut.accessibilityIdentifier = "library.debut"
        debut.alpha = 1
        debut.onDismiss = { [weak self] in self?.finishDebut() }
        debut.onShowPaywall = { [weak self] in
            guard let self else { return }
            PaywallViewController.presentSheet(from: self)
        }
        view.addSubview(debut)
        debutView = debut
        navigationController?.setNavigationBarHidden(true, animated: false)

        NSLayoutConstraint.activate([
            debut.topAnchor.constraint(equalTo: view.topAnchor),
            debut.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            debut.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            debut.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupStatusBanner() {
        statusBanner.accessibilityIdentifier = "library.statusBanner"
        statusBanner.onTap = { [weak self] in
            guard let self else { return }
            if self.viewModel.debutIsPending, self.debutView != nil {
                self.presentDebutSheet()
            } else {
                self.navigationController?.pushViewController(EnrichmentReportViewController(), animated: true)
            }
        }
        view.addSubview(statusBanner)
        statusBannerHeight = statusBanner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            statusBanner.topAnchor.constraint(equalTo: filterChipsView.bottomAnchor),
            statusBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBannerHeight,
        ])
    }

    /// Renders exactly the surface the router asked for, and nothing derived.
    ///
    /// The Debut is repainted on **every** snapshot, before visibility is
    /// decided. Painting it only inside the "is it showing?" branch is what left
    /// the ring frozen at 1%: the restored library flipped the branch between
    /// the first snapshot and the second, so the second never reached the view.
    private func render(loadState state: LibraryViewModel.LibraryLoadState, animated: Bool = true) {
        updateDebut(with: state)

        switch state.surface {
        case .debut:
            guard debutView != nil else {
                viewModel.dismissDebut()
                return
            }
            showDebut()
            setStatusBanner(visible: false, animated: false)
        case .ambient:
            demoteDebutToSheet()
            showAmbient(state, animated: animated)
        case .none:
            demoteDebutToSheet()
            setStatusBanner(visible: false, animated: animated)
        }
    }

    /// Takes the Debut off the screen the moment the library behind it is worth
    /// looking at, without throwing away what it still has to show. The view
    /// keeps living — the mosaic keeps filling, the countdown keeps counting —
    /// but from here it is reached through the banner or raised once for the
    /// summary, never left standing in the reader's way.
    private func demoteDebutToSheet() {
        guard let debut = debutView, debut.superview === view else { return }
        debut.removeFromSuperview()
        navigationController?.setNavigationBarHidden(false, animated: true)
    }

    /// Opens the Debut over whatever the reader is doing, on their say-so.
    private func presentDebutSheet() {
        guard let debut = debutView, presentedViewController == nil else { return }
        let sheet = LibraryDebutSheetController(debutView: debut)
        debutSheet = sheet
        present(sheet, animated: true)
    }

    private func dismissDebutSheet(completion: (() -> Void)? = nil) {
        guard let sheet = debutSheet, presentedViewController === sheet else {
            completion?()
            return
        }
        debutSheet = nil
        sheet.dismiss(animated: true, completion: completion)
    }

    private func updateDebut(with state: LibraryViewModel.LibraryLoadState) {
        guard let debutView else { return }
        let act = viewModel.debutAct
        debutView.update(progress: state.progress, fraction: state.fraction, job: state.job, act: act)
        feedDebutMosaic()
        guard renderedDebutAct != act else { return }
        renderedDebutAct = act
        enter(act)
    }

    /// Pours the artwork the built library holds into the mosaic — the backstop
    /// for anything Act I's live feed missed, and the only source once the scan
    /// found no new files to read.
    private func feedDebutMosaic() {
        for album in viewModel.mosaicAlbums() where fedMosaicKeys.count < LibraryViewModel.mosaicCoverBudget {
            guard fedMosaicKeys.insert(album.id).inserted else { continue }
            loadMosaicCover(albumTitle: album.title, artist: album.artist, tileKey: album.id)
        }
    }

    /// Fills the mosaic *during* Act I, from the covers the scan is hoisting out
    /// of the tags as it reads them. This is the act's whole show: the album
    /// model does not exist until the phase after it, so without this the grid
    /// stays a wall of gradients for the entire scan and then fills all at once.
    private func absorbHoistedCovers(_ notification: Notification) {
        guard debutView != nil,
              let covers = notification.userInfo?[Library.CoverKey.covers] as? [HoistedAlbumCover]
        else { return }
        for cover in covers where fedMosaicKeys.count < LibraryViewModel.mosaicCoverBudget {
            guard fedMosaicKeys.insert(cover.tileKey).inserted else { continue }
            loadMosaicCover(albumTitle: cover.albumTitle, artist: cover.artist, tileKey: cover.tileKey)
        }
    }

    /// Decodes one cover off the main thread and places it under the identity the
    /// album model will carry, so the live feed and the post-build pass cannot
    /// tile the same album twice.
    private func loadMosaicCover(albumTitle: String, artist: String, tileKey: String) {
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: albumTitle, artist: artist) { [weak self] image in
            guard let image, let debutView = self?.debutView else { return }
            debutView.insert(cover: image, forKey: tileKey)
        }
    }

    /// Moves the Debut into an act. No haptic fires here: the Debut's single
    /// haptic belongs to `LibraryDebutView.presentSummary(_:aiSkippedForEntitlement:)`, which plays it
    /// at the moment the card actually rises rather than one database pass
    /// earlier. Acts I and II are background work, and the HIG is explicit that
    /// background work does not get repeated feedback.
    private func enter(_ act: LibraryDebutAct) {
        switch act {
        case .indexing, .finishing:
            break
        case .summary:
            if debutView?.superview !== view { presentDebutSheet() }
            presentDebutSummary()
        case .done:
            viewModel.dismissDebut()
        }
    }

    private func presentDebutSummary() {
        Task { [weak self] in
            guard let self else { return }
            let summary = await self.viewModel.debutSummary()
            self.debutSummary = summary
            self.debutView?.presentSummary(
                summary, aiSkippedForEntitlement: self.viewModel.aiSkippedForEntitlement
            )
        }
    }

    /// Leaves the Debut for good, recording the summary the person just read so
    /// no later launch can offer them the showpiece again, and flying the mosaic
    /// onto the album grid it was a picture of all along.
    ///
    /// The grid's frames are measured and the view is released *before* the
    /// latch is dropped: releasing it raises the status banner, which would
    /// otherwise shift the grid under tiles already in flight. Nilling the
    /// property up front also makes `updateDebut` a no-op for the
    /// duration, so no second crossfade competes with the morph — which leaves
    /// the nav bar to be restored by hand.
    private func finishDebut() {
        guard let debut = debutView else { return }
        guard debut.superview === view else {
            debutView = nil
            if let debutSummary {
                viewModel.completeDebut(with: debutSummary)
            } else {
                viewModel.dismissDebut()
            }
            dismissDebutSheet { [weak self] in
                debut.removeFromSuperview()
                self?.retireDebutState()
            }
            return
        }
        view.layoutIfNeeded()
        let targets = UIAccessibility.isReduceMotionEnabled ? [] : albumGridTargetFrames(in: debut)
        debutView = nil
        view.bringSubviewToFront(debut)
        navigationController?.setNavigationBarHidden(false, animated: false)
        if let debutSummary {
            viewModel.completeDebut(with: debutSummary)
        } else {
            viewModel.dismissDebut()
        }
        debut.morph(to: targets) { [weak self] in
            debut.removeFromSuperview()
            self?.retireDebutState()
        }
    }

    /// The frames the album grid's first screen is about to occupy, in the debut
    /// view's own space, so the tiles land on their own counterparts.
    private func albumGridTargetFrames(in space: UIView) -> [CGRect] {
        collectionView.indexPathsForVisibleItems
            .sorted()
            .compactMap { collectionView.layoutAttributesForItem(at: $0)?.frame }
            .map { collectionView.convert($0, to: space) }
    }

    /// Drops everything the Debut was holding — thirty-six decoded covers, the
    /// summary it read from, and the keys that stopped it tiling an album twice.
    private func retireDebutState() {
        renderedDebutAct = nil
        debutSummary = nil
        fedMosaicKeys.removeAll()
    }

    private func showDebut() {
        guard let debutView, debutView.isHidden || debutView.alpha < 1 else { return }
        debutView.isHidden = false
        debutView.alpha = 1
        view.bringSubviewToFront(debutView)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    /// The quiet surface: one line under the segments reporting work going on
    /// behind a library the person can already use. A live disk scan wins the
    /// line, because it is the thing that changes what is on screen; the job
    /// gets it the rest of the time.
    private func showAmbient(_ state: LibraryViewModel.LibraryLoadState, animated: Bool) {
        if statusBannerHeight.constant == 0 { statusBanner.prepareForShow() }
        statusBanner.update(
            state.progress.isActive ? .load(state.progress, state.fraction) : .job(state.job)
        )
        setStatusBanner(visible: true, animated: animated)
    }

    private func setStatusBanner(visible: Bool, animated: Bool) {
        let target = visible ? LibraryStatusBanner.expandedHeight : 0
        guard statusBannerHeight.constant != target else { return }
        statusBannerHeight.constant = target
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            view.layoutIfNeeded()
            return
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) {
            self.view.layoutIfNeeded()
        }
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
            heart.accessibilityLabel = String(localized: "Loved")
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
        label.text = count > 999 ? String(localized: "\(count / 1000)k") : "\(count)"
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel

        stack.addArrangedSubview(glyph)
        stack.addArrangedSubview(label)
        stack.isAccessibilityElement = true
        stack.accessibilityLabel = String(localized: "\(count) scrobbles")
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
            content.secondaryText = String(localized: "\(artist.albumCount) albums")
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
            content.secondaryText = String(localized: "\(playlist.trackCount) tracks")
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
            content.secondaryText = String(localized: "\(suggestion.subtitle) · \(suggestion.tracks.count) songs")
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
            content.text = String(localized: "Recap")
            content.secondaryText = String(localized: "Your listening stats")
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "chart.bar.fill")
            content.imageProperties.tintColor = .systemPink
            content.imageProperties.maximumSize = CGSize(width: 44, height: 44)
            content.imageProperties.reservedLayoutSize = CGSize(width: 44, height: 44)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
            cell.accessibilityIdentifier = "library.playlists.recap"
        }

        let wantlistRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, _ in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = String(localized: "Wantlist")
            let unseen = WantlistService.shared.unseenCount()
            content.secondaryText = unseen > 0
                ? String(localized: "\(unseen) new suggestions")
                : String(localized: "Music to get & discoveries")
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
            config.text = String(localized: "Recently Played")
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
                let layout = self.viewModel.layoutMode
                let segmentChanged = self.lastRenderedSegment != nil && self.lastRenderedSegment != segment
                let filterChanged = self.lastRenderedFilter != nil && self.lastRenderedFilter != filter
                let previousSegment = self.lastRenderedSegment
                self.lastRenderedSegment = segment
                self.lastRenderedFilter = filter
                self.filterChipsView.setSelected(filter, animated: false)
                let useReload = self.shouldReload(
                    snapshot, segmentChanged: segmentChanged, isFirstRender: previousSegment == nil
                )
                self.applyLibrarySnapshot(
                    snapshot,
                    segment: segment,
                    layout: layout,
                    forceLayout: segmentChanged || filterChanged,
                    useReload: useReload
                )
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: LovedTracksService.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleLovedChange() }
            .store(in: &cancellables)

        viewModel.loadStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.render(loadState: state) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Library.albumCoversHoisted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in self?.absorbHoistedCovers(notification) }
            .store(in: &cancellables)

        render(loadState: viewModel.currentLoadState, animated: false)
    }

    /// Whether to swap the list wholesale instead of diffing it.
    ///
    /// A full list swap of a large library is far cheaper as a reload than as a
    /// 6 000-item identity diff, but a library refresh keeps its rows — and
    /// during the Debut's second act the AI is retitling albums under a reader
    /// who is scrolling, where a reload would tear the grid down rather than
    /// move the one row that changed.
    private func shouldReload(
        _ snapshot: LibraryViewModel.Snapshot, segmentChanged: Bool, isFirstRender: Bool
    ) -> Bool {
        if segmentChanged || isFirstRender { return true }
        guard viewModel.snapshotIntent == .replaceList else { return false }
        return snapshot.numberOfItems > 200
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
            title: loved ? String(localized: "Unlove") : String(localized: "Love")
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
                        let headerSize = NSCollectionLayoutSize(
                            widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(32)
                        )
                        section.boundarySupplementaryItems = [
                            NSCollectionLayoutBoundarySupplementaryItem(
                                layoutSize: headerSize,
                                elementKind: UICollectionView.elementKindSectionHeader,
                                alignment: .top
                            )
                        ]
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
                let deleteAction = UIContextualAction(style: .destructive, title: String(localized: "Delete")) { _, _, completion in
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
        let play = UIAction(title: String(localized: "Play"), image: UIImage(systemName: "play.fill")) { _ in
            AudioPlayer.shared.play(tracks, startingAt: 0)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        let shuffle = UIAction(title: String(localized: "Shuffle"), image: UIImage(systemName: "shuffle")) { _ in
            AudioPlayer.shared.play(tracks.shuffled(), startingAt: 0)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        let playNext = UIAction(title: String(localized: "Play Next"), image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { _ in
            for track in tracks.reversed() { AudioPlayer.shared.insertNext(track) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        let addToQueue = UIAction(title: String(localized: "Add to Queue"), image: UIImage(systemName: "text.append")) { _ in
            for track in tracks { AudioPlayer.shared.addToQueue(track) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        let save = UIAction(title: String(localized: "Save as Playlist"), image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
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
            ToastView.show(String(localized: "Saved \u{201C}\(suggestion.title)\u{201D}"), in: view, style: .success)
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
            ToastView.show(String(localized: "Playing \(suggestion.title)"), in: view, style: .success)
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
                let playAction = UIAction(title: String(localized: "Play"), image: UIImage(systemName: "play.fill")) { _ in
                    AudioPlayer.shared.play(album.tracks, startingAt: 0)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                let shuffleAction = UIAction(title: String(localized: "Shuffle"), image: UIImage(systemName: "shuffle")) { _ in
                    var shuffled = album.tracks
                    shuffled.shuffle()
                    AudioPlayer.shared.play(shuffled, startingAt: 0)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                let playNextAction = UIAction(title: String(localized: "Play Next"), image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { _ in
                    for track in album.tracks.reversed() {
                        AudioPlayer.shared.insertNext(track)
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                let addToQueueAction = UIAction(title: String(localized: "Add to Queue"), image: UIImage(systemName: "text.append")) { _ in
                    for track in album.tracks {
                        AudioPlayer.shared.addToQueue(track)
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                let shareAlbum = UIAction(title: String(localized: "Share"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    guard let self else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    self.shareAlbumViaSonglink(title: album.title, artist: album.artist, from: self.view)
                }
                let shareMenu = UIMenu(options: .displayInline, children: [shareAlbum])
                let deleteAlbum = UIAction(title: String(localized: "Delete from Library"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    guard let self else { return }
                    TrackContextMenu.confirmDelete(
                        title: String(localized: "Delete \"\(album.title)\"?"),
                        message: String(localized: "All \(album.tracks.count) tracks will be removed from this device."),
                        in: self
                    ) { [weak self] in
                        Task { @MainActor in
                            await Library.shared.deleteTracks(album.tracks)
                            if let self {
                                ToastView.show(String(localized: "Deleted \(album.title)"), in: self.view, style: .info)
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
