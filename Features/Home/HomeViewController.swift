import Combine
import FlaccyCore
import MidgarCore
import UIKit

/// The iPhone's launch screen: what to play next, laid out from the library
/// and the person's own listening, in the order they chose.
final class HomeViewController: UIViewController {

    weak var tabController: AppTabBarController?

    let viewModel = HomeViewModel()
    let libraryViewModel: LibraryViewModel
    let library: LibraryViewController
    var model: HomeScreenModel = .empty
    var collectionView: UICollectionView!
    var dataSource: UICollectionViewDiffableDataSource<HomeSectionID, HomeItem>!

    private let backdrop = HomeBackdropView()
    private let launchPlaceholder = HomeLaunchPlaceholderView()
    private let runwayBanner = TrialRunwayBannerView()
    private let statusBanner = LibraryStatusBanner()
    private var placeholderInsets: (leading: NSLayoutConstraint, trailing: NSLayoutConstraint)?
    private var runwayHeight: NSLayoutConstraint!
    private var statusHeight: NSLayoutConstraint!
    private var runwayRequested = false
    private var showsStatusBanner = false
    private var hasRendered = false
    var isRestoring = false
    private(set) var isWide = false
    private var cancellables = Set<AnyCancellable>()

    init(libraryViewModel: LibraryViewModel, library: LibraryViewController) {
        self.libraryViewModel = libraryViewModel
        self.library = library
        super.init(nibName: nil, bundle: nil)
        title = HomeCopy.home
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .always
        setupSettingsButton()
        setupBackdrop()
        setupCollectionView()
        setupLaunchPlaceholder()
        setupDataSource()
        setupBanners()
        bindSources()
        viewModel.reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.reload()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        positionBackdrop()
        updateWidth()
        let width = collectionView.bounds.width
        let target = runwayBanner.expandedHeight(forWidth: width)
        if runwayHeight.constant != target { runwayHeight.constant = target }
        if let placeholderInsets {
            let inset = AdaptiveLayout.homeIsWide(contentWidth: contentWidth) ? 24.0 : 16.0
            placeholderInsets.leading.constant = inset
            placeholderInsets.trailing.constant = -inset
        }
    }

    /// Home arranges itself from the room its own content area has, and
    /// re-arranges when that changes, as when the Duo opens its inner display
    /// or the window is resized.
    private func updateWidth() {
        let width = contentWidth
        let wide = AdaptiveLayout.homeIsWide(contentWidth: width)
        guard wide != isWide, hasRendered else {
            if !hasRendered { isWide = wide }
            return
        }
        isWide = wide
        reapply()
    }

    private func setupSettingsButton() {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            primaryAction: UIAction { [weak self] _ in self?.presentSettings() }
        )
        item.accessibilityLabel = HomeCopy.settings
        item.accessibilityIdentifier = "home.settings"
        navigationItem.rightBarButtonItem = item
    }

    private func setupBackdrop() {
        backdrop.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: HomeBackdropView.fadeHeight)
        view.addSubview(backdrop)
    }

    private func setupCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .scrollableAxes
        collectionView.contentInset.bottom = 16
        collectionView.accessibilityIdentifier = "home.collection"
        view.addSubview(collectionView)
        setContentScrollView(collectionView, for: .top)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Holds the page back until its first real frame, with the placeholder
    /// standing where the hero and the first shelves will be.
    private func setupLaunchPlaceholder() {
        collectionView.alpha = 0
        launchPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(launchPlaceholder)
        let guide = view.safeAreaLayoutGuide
        let leading = launchPlaceholder.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16)
        let trailing = launchPlaceholder.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16)
        NSLayoutConstraint.activate([
            launchPlaceholder.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            launchPlaceholder.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            leading,
            trailing,
        ])
        placeholderInsets = (leading, trailing)
        launchPlaceholder.appear()
    }

    /// The page fades up over the placeholder and settles a few points into
    /// place, its covers already loaded, while the placeholder fades out.
    private func revealFirstFrame() {
        launchPlaceholder.dismiss()
        placeholderInsets = nil
        let animates = view.window != nil && !Self.isScreenshotLaunch
        guard animates else {
            collectionView.alpha = 1
            return
        }
        let rises = !UIAccessibility.isReduceMotionEnabled
        if rises { collectionView.transform = CGAffineTransform(translationX: 0, y: 12) }
        UIView.animate(
            withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.collectionView.alpha = 1
            self.collectionView.transform = .identity
        }
    }

    /// A DEBUG screenshot launch, whose captures must not catch the page mid
    /// fade. Always false in a release build, where the seeder does not exist.
    private static var isScreenshotLaunch: Bool {
        #if DEBUG && (targetEnvironment(simulator) || os(macOS))
        ScreenshotSeeder.isActive
        #else
        false
        #endif
    }

    private func setupBanners() {
        runwayBanner.onGetLifetime = { PurchaseManager.shared.requestPaywall() }
        runwayBanner.onDismiss = { [weak self] in
            PurchaseManager.shared.markRunwayPromptShown()
            self?.setRunwayBanner(visible: false)
            MidgarLog.info("Runway banner dismissed on Home", category: .purchases)
        }
        runwayHeight = runwayBanner.heightAnchor.constraint(equalToConstant: 0)
        runwayHeight.isActive = true

        statusBanner.accessibilityIdentifier = "home.statusBanner"
        statusBanner.onTap = { [weak self] in self?.statusBannerTapped() }
        statusHeight = statusBanner.heightAnchor.constraint(equalToConstant: LibraryStatusBanner.expandedHeight)
        statusHeight.isActive = true
        runwayRequested = PurchaseManager.shared.runwayBannerIsDue
    }

    private func bindSources() {
        viewModel.onUpdate = { [weak self] model in self?.apply(model) }
        libraryViewModel.loadStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.render(loadState: state) }
            .store(in: &cancellables)
        render(loadState: libraryViewModel.currentLoadState)
        NotificationCenter.default.publisher(for: SampleMusicService.progressDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshGetStartedCell() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AlbumArtworkCache.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.viewModel.refresh() }
            .store(in: &cancellables)
    }

    func setRunwayBanner(visible: Bool) {
        guard isViewLoaded else {
            runwayRequested = visible
            return
        }
        guard runwayRequested != visible else { return }
        runwayRequested = visible
        reapply()
    }

    /// The last-day card says the same thing the runway banner does, so only one of them is up.
    private var showsRunwayBanner: Bool {
        runwayRequested && !library.debutOwnsScreen && model.feed.promo != .lastDay
    }

    private func render(loadState state: LibraryViewModel.LibraryLoadState) {
        switch state.surface {
        case .ambient:
            if !showsStatusBanner { statusBanner.prepareForShow() }
            statusBanner.update(state.progress.isActive ? .load(state.progress, state.fraction) : .job(state.job))
            guard !showsStatusBanner else { return }
            showsStatusBanner = true
            reapply()
        case .debut, .none:
            guard showsStatusBanner else { return }
            showsStatusBanner = false
            reapply()
        }
    }

    private func statusBannerTapped() {
        if libraryViewModel.debutIsPending, library.isShowingDebut {
            library.performWhenVisible { [library] in library.presentDebutSheet() }
        } else {
            navigationController?.pushViewController(EnrichmentReportViewController(), animated: true)
        }
    }

    private func reapply() {
        guard isViewLoaded, dataSource != nil else { return }
        apply(model)
    }

    private func apply(_ newModel: HomeScreenModel) {
        guard viewModel.hasLoaded else { return }
        model = newModel
        let isFirstFrame = !hasRendered
        let plan = HomeSnapshotPlan.sections(
            for: newModel, showsRunwayBanner: showsRunwayBanner, showsStatusBanner: showsStatusBanner,
            isWide: isWide
        )
        var snapshot = NSDiffableDataSourceSnapshot<HomeSectionID, HomeItem>()
        for (section, items) in plan {
            snapshot.appendSections([section])
            snapshot.appendItems(items, toSection: section)
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter(existing.contains))
        let animates = hasRendered && !UIAccessibility.isReduceMotionEnabled && view.window != nil
        dataSource.apply(snapshot, animatingDifferences: animates)
        hasRendered = true
        collectionView.collectionViewLayout.invalidateLayout()
        backdrop.show(album: newModel.backdropAlbum)
        view.setNeedsLayout()
        if isFirstFrame {
            view.layoutIfNeeded()
            revealFirstFrame()
        }
    }

    /// The sample album's button is the one place its download shows, so it
    /// follows the service while the card is on screen.
    func refreshGetStartedCell() {
        library.applySampleButtonState()
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(.getStarted) else { return }
        snapshot.reconfigureItems([.getStarted])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The words of the promo card the feed asks for, or nil when it asks for none.
    var promoContent: HomePromoContent? {
        model.feed.promo.map { HomePromoContent.make(for: $0, proof: model.feed.proofLines) }
    }

    func positionBackdrop() {
        let scrolled = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        backdrop.frame = CGRect(x: 0, y: -scrolled, width: view.bounds.width, height: HomeBackdropView.fadeHeight)
    }

    func presentSettings() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let settings = SettingsViewController()
        settings.onImportFiles = { [library] in library.performWhenVisible { library.importTapped() } }
        let navigation = UINavigationController(rootViewController: settings)
        navigation.modalPresentationStyle = .pageSheet
        present(navigation, animated: true)
    }

    func presentEditHome() {
        let editor = EditHomeViewController()
        editor.modalPresentationStyle = .pageSheet
        editor.sheetPresentationController?.detents = [.large()]
        editor.sheetPresentationController?.prefersGrabberVisible = true
        present(editor, animated: true)
    }

    #if DEBUG
    func demoScroll(fraction: CGFloat) {
        view.layoutIfNeeded()
        let top = -collectionView.adjustedContentInset.top
        let maximum = collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
        collectionView.setContentOffset(CGPoint(x: 0, y: top + max(maximum - top, 0) * fraction), animated: false)
    }
    #endif

    var runwayBannerView: UIView { runwayBanner }
    var statusBannerView: UIView { statusBanner }
}

extension HomeViewController: UICollectionViewDelegate {

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        positionBackdrop()
    }
}
