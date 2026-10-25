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
    private let runwayBanner = TrialRunwayBannerView()
    private let statusBanner = LibraryStatusBanner()
    private var runwayHeight: NSLayoutConstraint!
    private var statusHeight: NSLayoutConstraint!
    private var runwayRequested = false
    private var showsStatusBanner = false
    private var hasRendered = false
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
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
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
            .sink { [weak self] _ in self?.refreshEmptyCell() }
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

    private var showsRunwayBanner: Bool {
        runwayRequested && !library.debutOwnsScreen
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
        model = newModel
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
    }

    func refreshEmptyCell() {
        library.applySampleButtonState()
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(.empty) else { return }
        snapshot.reconfigureItems([.empty])
        dataSource.apply(snapshot, animatingDifferences: false)
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
