import Combine
import MidgarCore
import FlaccyCore
import UIKit
import UniformTypeIdentifiers

final class LibraryViewController: UIViewController, SonglinkShareable {

    let viewModel = LibraryViewModel()
    var collectionView: UICollectionView!
    var dataSource: UICollectionViewDiffableDataSource<Int, LibraryItem>!
    let segmentedControl = IdentifiedSegmentedControl(
        items: [String(localized: "Albums"), String(localized: "Songs"), String(localized: "Artists"), String(localized: "Playlists")],
        identifiers: ["library.tab.albums", "library.tab.songs", "library.tab.artists", "library.tab.playlists"]
    )
    var cancellables = Set<AnyCancellable>()
    let playlistAlbumIndex = PlaylistAlbumIndex()
    let impactLight = UIImpactFeedbackGenerator(style: .light)
    let sectionIndexView = SectionIndexView()
    let filterChipsView = FilterChipsView()
    let sourceChipsView = SourceChipsView()
    var chipsHeightConstraint: NSLayoutConstraint!
    var sourceChipsHeightConstraint: NSLayoutConstraint!
    var lastRenderedFilter: LibraryFilter?
    var lastRenderedLayout: LibraryLayoutMode?
    let selectionFeedback = UISelectionFeedbackGenerator()
    var debutView: LibraryDebutView?
    weak var debutSheet: LibraryDebutSheetController?
    var renderedDebutAct: LibraryDebutAct?
    var debutSummary: LibraryDebutSummary?
    var fedMosaicKeys = Set<String>()
    let statusBanner = LibraryStatusBanner()
    var statusBannerHeight: NSLayoutConstraint!
    let runwayBanner = TrialRunwayBannerView()
    var runwayBannerHeight: NSLayoutConstraint!
    var runwayBannerRequested = false

    /// Where the full-screen Debut lives. The root container supplies its own
    /// view so the showpiece covers the tab bar, the mini player and the other
    /// tabs too; on its own the Library hosts it.
    var debutHostProvider: (() -> UIView?)?

    var debutHost: UIView {
        debutHostProvider?() ?? view
    }

    /// Posted once the Debut is over for good — its summary read and the view
    /// retired, or the showpiece skipped — so anything that waited on it, the
    /// paywall above all, can go ahead. A demotion to the banner is not the end:
    /// the summary sheet still raises itself later, and a paywall presented in
    /// between would block it.
    static let debutDidDismiss = Notification.Name("LibraryDebutDidDismiss")

    /// True while the Debut still has something to show: full-screen, as the
    /// raised sheet, or demoted behind the banner with its summary pending.
    var isShowingDebut: Bool {
        debutView != nil
    }

    var debutOwnsScreen: Bool {
        if let debutView, debutView.superview === debutHost { return true }
        return presentedViewController is LibraryDebutSheetController
    }
    let emptyStateIconView = UIImageView(image: UIImage(systemName: "music.note.list"))
    let emptyStateLabel = UILabel()
    let trialStartsLabel = UILabel()
    var lastRenderedSegment: LibraryViewModel.Segment?
    lazy var addMusicButton: UIButton = {
        var config = UIButton.Configuration.borderedProminent()
        config.title = String(localized: "Add Music")
        config.image = UIImage(systemName: "plus")
        config.imagePadding = 8
        config.cornerStyle = .large
        return UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.importTapped()
        })
    }()
    lazy var sampleMusicButton: UIButton = {
        var config = UIButton.Configuration.bordered()
        config.title = String(localized: "Add Sample Music")
        config.subtitle = String(localized: "Bach, lossless, free · 130 MB")
        config.image = UIImage(systemName: "arrow.down.circle")
        config.imagePadding = 8
        config.titleAlignment = .center
        config.cornerStyle = .large
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.sampleMusicTapped()
        })
        return button
    }()
    lazy var computerGuideButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = String(localized: "Moving music from a computer")
        config.image = UIImage(systemName: "laptopcomputer.and.iphone")
        config.imagePadding = 6
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .subheadline)
            return attributes
        }
        return UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            self?.presentComputerTransferGuide()
        })
    }()
    lazy var emptyStateView: UIView = {
        let container = UIView()

        let imageView = emptyStateIconView
        imageView.tintColor = .tertiaryLabel
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 56, weight: .thin)
        imageView.contentMode = .scaleAspectFit

        let label = emptyStateLabel
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center

        let buttons = UIStackView(arrangedSubviews: [addMusicButton, sampleMusicButton])
        buttons.axis = .vertical
        buttons.spacing = 10
        buttons.alignment = .fill
        let preferredButtonWidth = buttons.widthAnchor.constraint(equalToConstant: 300)
        preferredButtonWidth.priority = .defaultHigh

        let footnote = trialStartsLabel
        footnote.text = PaywallCopy.trialStartsLine
        footnote.textColor = .tertiaryLabel
        footnote.font = .preferredFont(forTextStyle: .footnote)
        footnote.adjustsFontForContentSizeCategory = true
        footnote.numberOfLines = 0
        footnote.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [imageView, label, buttons, computerGuideButton, footnote])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.setCustomSpacing(24, after: label)
        stack.setCustomSpacing(6, after: buttons)
        stack.setCustomSpacing(14, after: computerGuideButton)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentInsetAdjustmentBehavior = .automatic
        scrollView.showsVerticalScrollIndicator = false
        let page = UIView()
        page.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        scrollView.addSubview(page)
        container.addSubview(scrollView)

        let centered = stack.centerYAnchor.constraint(equalTo: page.centerYAnchor, constant: -40)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredButtonWidth,
            buttons.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            page.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            page.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            page.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            page.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),
            stack.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            centered,
            stack.topAnchor.constraint(greaterThanOrEqualTo: page.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: page.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -32),
        ])

        return container
    }()

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard viewModel.currentSegment == .playlists else { return }
        playlistAlbumIndex.invalidate()
        reconfigureVisibleArtwork()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        installDebutViewIfNeeded()

        setupSearchController()
        setupSegmentedControl()
        setupFilterChips()
        setupSourceChips()
        setupRunwayBanner()
        setupStatusBanner()
        setupCollectionView()
        setupSectionIndex()
        configureDataSource()
        if let debutView { debutHost.bringSubviewToFront(debutView) }
        bindViewModel()
        updateRightBarButton(for: .albums)
        updateChips(for: .albums)
        #if DEBUG
        driveSampleFlowIfRequested()
        #endif

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

    /// Runs `action` with the Library on screen. Pickers, sheets and toasts the
    /// Library raises need its view in a window, so from any other tab the
    /// Library is brought forward first.
    func performWhenVisible(_ action: @escaping () -> Void) {
        guard view.window == nil, let tabs = tabBarController as? AppTabBarController else {
            action()
            return
        }
        tabs.show(.library)
        DispatchQueue.main.async { action() }
    }

    func select(segment: LibraryViewModel.Segment) {
        loadViewIfNeeded()
        segmentedControl.selectedSegmentIndex = segment.rawValue
        segmentedControl.sendActions(for: .valueChanged)
    }

    /// Opens the Albums segment on its Recently Added pivot, the way Home's
    /// "See All" asks for it.
    func showRecentlyAdded() {
        select(segment: .albums)
        viewModel.setFilter(.recentlyAdded)
    }

    func demoSelect(segment: LibraryViewModel.Segment) {
        select(segment: segment)
    }

    func observeWantlist() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(wantlistDidChange), name: WantlistService.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(wantlistDidResolve(_:)), name: WantlistService.didResolveItems, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(entitlementDidChange), name: PurchaseManager.stateDidChange, object: nil
        )
    }

    @objc func entitlementDidChange() {
        updateEmptyState()
    }

    @objc func wantlistDidChange() {
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(.wantlist) else { return }
        snapshot.reconfigureItems([.wantlist])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    @objc func wantlistDidResolve(_ notification: Notification) {
        guard let names = notification.userInfo?["names"] as? [String], !names.isEmpty else { return }
        let summary = names.count == 1
            ? String(localized: "Crossed off your Wantlist: \(names[0])")
            : String(localized: "Crossed off your Wantlist: \(names[0]) and \(names.count - 1) more")
        ToastView.show(summary, in: view, style: .success)
        wantlistDidChange()
    }

    func setupSearchController() {
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
    func setupSegmentedControl() {
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
            segmentedControl.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            segmentedControl.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
    }

    /// Rebuilds the compositional layout for the current mode and reapplies the
    /// snapshot, optionally under a sub-350ms crossfade unless Reduce Motion is on.
    func applyLayoutAndSnapshot(crossfade: Bool) {
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
    func applyLibrarySnapshot(
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

    func createPlaylistTapped() {
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
                MidgarLog.error("Failed to create playlist: \(error.localizedDescription)", category: .database)
                if let self { ToastView.show(String(localized: "Couldn't create \u{201C}\(name)\u{201D} — the library database couldn't be written. Check free disk space and try again."), in: self.view, style: .error) }
            }
        })
        present(alert, animated: true)
    }

    func setupFilterChips() {
        filterChipsView.translatesAutoresizingMaskIntoConstraints = false
        filterChipsView.onSelect = { [weak self] filter in
            self?.viewModel.setFilter(filter)
            self?.updateSectionIndex()
        }
        view.addSubview(filterChipsView)
        chipsHeightConstraint = filterChipsView.heightAnchor.constraint(equalToConstant: 46)
        NSLayoutConstraint.activate([
            filterChipsView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 8),
            filterChipsView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            filterChipsView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            chipsHeightConstraint,
        ])
    }

    func updateChips(for segment: LibraryViewModel.Segment) {
        let showsChips = segment == .albums || segment == .songs
        filterChipsView.isHidden = !showsChips
        chipsHeightConstraint.constant = showsChips ? 46 : 0
        updateSourceChips(for: segment)
        guard showsChips else { return }
        filterChipsView.configure(filters: viewModel.availableFilters(), selected: viewModel.filter)
    }

    func setupSourceChips() {
        sourceChipsView.translatesAutoresizingMaskIntoConstraints = false
        sourceChipsView.isHidden = true
        sourceChipsView.accessibilityIdentifier = "library.sourceChips"
        sourceChipsView.onSelect = { [weak self] source in
            self?.viewModel.setSource(source)
            self?.updateSectionIndex()
        }
        view.addSubview(sourceChipsView)
        sourceChipsHeightConstraint = sourceChipsView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            sourceChipsView.topAnchor.constraint(equalTo: filterChipsView.bottomAnchor),
            sourceChipsView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            sourceChipsView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            sourceChipsHeightConstraint,
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(remoteServersDidChange), name: RemoteServers.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(serverSyncChangesDidArrive), name: ServerSyncLifecycle.changesDidArrive, object: nil
        )
    }

    @objc func serverSyncChangesDidArrive() {
        viewModel.refreshPlaylists()
    }

    @objc func remoteServersDidChange() {
        updateSourceChips(for: viewModel.currentSegment)
    }

    /// Shows the source row on Albums and Songs while a server is added, and widens the list to
    /// every source when the one it was narrowed to is gone.
    func updateSourceChips(for segment: LibraryViewModel.Segment) {
        let choices = viewModel.sourceChoices()
        if let source = viewModel.source, !choices.contains(where: { $0.source == source }) {
            viewModel.setSource(nil)
        }
        let shows = (segment == .albums || segment == .songs) && !choices.isEmpty
        sourceChipsView.isHidden = !shows
        sourceChipsHeightConstraint.constant = shows ? 42 : 0
        guard shows else { return }
        sourceChipsView.configure(choices: choices, selected: viewModel.source)
    }

    func setupCollectionView() {
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

    func setupSectionIndex() {
        sectionIndexView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sectionIndexView)

        NSLayoutConstraint.activate([
            sectionIndexView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 2),
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

    func updateEmptyState() {
        switch viewModel.emptyState {
        case .none:
            collectionView.backgroundView = nil
        case .noLibrary:
            emptyStateIconView.image = UIImage(systemName: "music.note.list")
            emptyStateLabel.text = String(localized: "Add songs or whole folders from iCloud Drive, a USB drive, or a network share you've connected in the Files app.")
            addMusicButton.isHidden = false
            sampleMusicButton.isHidden = false
            computerGuideButton.isHidden = false
            applySampleButtonState()
            trialStartsLabel.isHidden = PurchaseManager.shared.state != .trialNotStarted
            collectionView.backgroundView = emptyStateView
        case .noSearchResults(let query):
            emptyStateIconView.image = UIImage(systemName: "magnifyingglass")
            emptyStateLabel.text = String(localized: "No results for \u{201C}\(query)\u{201D}")
            addMusicButton.isHidden = true
            sampleMusicButton.isHidden = true
            computerGuideButton.isHidden = true
            trialStartsLabel.isHidden = true
            collectionView.backgroundView = emptyStateView
        }
    }

    func updateSectionIndex() {
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

    /// Renders exactly the surface the router asked for, and nothing derived.
    ///
    /// The Debut is repainted on **every** snapshot, before visibility is
    /// decided. Painting it only inside the "is it showing?" branch is what left
    /// the ring frozen at 1%: the restored library flipped the branch between
    /// the first snapshot and the second, so the second never reached the view.
    func render(loadState state: LibraryViewModel.LibraryLoadState, animated: Bool = true) {
        updateDebut(with: state)

        switch state.surface {
        case .debut:
            guard debutView != nil else {
                viewModel.dismissDebut()
                noteDebutFinished()
                return
            }
            showDebut()
            setStatusBanner(visible: false, animated: false)
        case .ambient:
            demoteDebutToSheet()
            if let sync = RemoteSyncStatus.shared.current {
                showRemoteSync(sync, animated: animated)
            } else {
                showAmbient(state, animated: animated)
            }
        case .none:
            demoteDebutToSheet()
            if let sync = RemoteSyncStatus.shared.current {
                showRemoteSync(sync, animated: animated)
            } else {
                setStatusBanner(visible: false, animated: animated)
            }
        }
        applyRunwayBannerVisibility(animated: animated)
    }

}
