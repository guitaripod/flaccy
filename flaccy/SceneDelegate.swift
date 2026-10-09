import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private let playerContainer = PlayerContainerViewController()
    private var navController: UINavigationController?
    private var rootController: RootContainerViewController?
    private var deferredPaywallObserver: NSObjectProtocol?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        #if DEBUG && targetEnvironment(simulator)
        ScreenshotSeeder.seedIfRequested()
        #endif

        let window = UIWindow(windowScene: windowScene)

        let nav = UINavigationController(rootViewController: LibraryViewController())
        nav.navigationBar.prefersLargeTitles = false
        self.navController = nav

        playerContainer.onRequestPush = { [weak nav] vc in
            nav?.pushViewController(vc, animated: true)
        }

        let rootVC = RootContainerViewController(navigation: nav, player: playerContainer)
        self.rootController = rootVC

        window.overrideUserInterfaceStyle = AppAppearance.current.userInterfaceStyle
        window.rootViewController = rootVC
        window.makeKeyAndVisible()
        self.window = window
        #if DEBUG
        PaywallShot.runIfRequested(in: window)
        SampleExercise.runIfRequested()
        #endif
        #if DEBUG && targetEnvironment(simulator)
        DemoRouter.runIfRequested(window: window, nav: nav, player: playerContainer)
        #endif

        NotificationCenter.default.addObserver(
            self, selector: #selector(trackDidChange), name: AudioPlayer.trackDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackStateDidChange), name: AudioPlayer.playbackStateDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleQueueTapped), name: MiniPlayerView.queueTapped, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePaywallRequired), name: PurchaseManager.paywallRequired, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(customerInfoDidLoad), name: PurchaseManager.customerInfoDidLoad, object: nil
        )
        TrialReminderPrompt.observeOpportunities()
    }

    /// The single place the paywall is presented from. A Debut on screen wins:
    /// the request waits for it to leave and is then presented exactly once.
    @objc private func handlePaywallRequired() {
        guard let top = TrialRunwayPresenter.topmostViewController(in: window) else { return }
        guard !(top is PaywallViewController) else { return }
        if let library = TrialRunwayPresenter.library(in: window), library.isShowingDebut {
            deferPaywallUntilDebutDismisses()
            return
        }
        PaywallViewController.presentSheet(from: top)
    }

    private func deferPaywallUntilDebutDismisses() {
        guard deferredPaywallObserver == nil else { return }
        AppLogger.info("Paywall deferred until the Debut dismisses", category: .purchases)
        deferredPaywallObserver = NotificationCenter.default.addObserver(
            forName: LibraryViewController.debutDidDismiss, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.deferredPaywallObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.deferredPaywallObserver = nil
                }
                self.handlePaywallRequired()
            }
        }
    }

    @objc private func customerInfoDidLoad() {
        TrialRunwayPresenter.refresh(in: window)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        TrialRunwayPresenter.refresh(in: window)
        Task {
            await RecapNotificationScheduler.shared.refreshSchedule()
        }
    }

    @objc private func handleQueueTapped() {
        playerContainer.expandShowingQueue()
    }

    @objc private func trackDidChange() {
        updateMiniPlayer()
    }

    @objc private func playbackStateDidChange() {
        updateMiniPlayer()
    }

    private func updateMiniPlayer() {
        let player = AudioPlayer.shared
        playerContainer.syncDock(track: player.currentTrack, isPlaying: player.isPlaying)
        rootController?.setHasCurrentTrack(player.currentTrack != nil)
    }
}

/// Root container. Under 840 pt it is the library with the player overlay
/// morphing over it; at 840 x 560 pt and up it is two panes, the library stack
/// beside a permanent Now Playing, each ending at the fold when there is one.
/// It also lets the player overlay drive the status bar, so it flips to light
/// content as the dark player expands over the library.
final class RootContainerViewController: UIViewController {
    weak var statusBarSource: UIViewController?

    private let navigation: UINavigationController
    private let player: PlayerContainerViewController
    private let dimmingView = UIView()
    private var navigationTrailing: NSLayoutConstraint!
    private var navigationWidth: NSLayoutConstraint!
    private var playerLeading: NSLayoutConstraint!
    private var appliedGeometry: AdaptiveLayout.SplitGeometry?
    private var hasCurrentTrack = false
    private(set) var isSplit = false
    private var isPlayerFocused = false

    override var childForStatusBarStyle: UIViewController? { statusBarSource }

    init(navigation: UINavigationController, player: PlayerContainerViewController) {
        self.navigation = navigation
        self.player = player
        navigation.view.translatesAutoresizingMaskIntoConstraints = false
        player.view.translatesAutoresizingMaskIntoConstraints = false
        super.init(nibName: nil, bundle: nil)
        statusBarSource = player
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        addChild(navigation)
        view.addSubview(navigation.view)
        navigation.didMove(toParent: self)

        dimmingView.backgroundColor = .black
        dimmingView.alpha = 0
        dimmingView.isUserInteractionEnabled = false
        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dimmingView)

        addChild(player)
        view.addSubview(player.view)
        player.didMove(toParent: self)
        player.onMorphProgress = { [weak self] progress in
            self?.dimmingView.alpha = 0.35 * progress
        }
        player.onFocusChange = { [weak self] focused in
            self?.setPlayerFocused(focused)
        }

        navigationTrailing = navigation.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        navigationWidth = navigation.view.widthAnchor.constraint(equalToConstant: 0)
        playerLeading = player.view.leadingAnchor.constraint(equalTo: view.leadingAnchor)

        NSLayoutConstraint.activate([
            navigation.view.topAnchor.constraint(equalTo: view.topAnchor),
            navigation.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navigation.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            playerLeading,
            player.view.topAnchor.constraint(equalTo: view.topAnchor),
            player.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            player.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimmingView.topAnchor.constraint(equalTo: navigation.view.topAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: navigation.view.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: navigation.view.trailingAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: navigation.view.bottomAnchor),
        ])
        applyCompactLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        if AdaptiveLayout.usesSplit(size: size) {
            let geometry = AdaptiveLayout.splitGeometry(width: size.width, division: view.divisionRegionFrame)
            guard !isSplit || geometry != appliedGeometry else { return }
            applySplitLayout(geometry)
        } else if isSplit {
            applyCompactLayout()
        }
    }

    /// Gives the player the whole window (artwork on one half, lyrics or the
    /// queue on the other, both ending at the fold) or hands the left half back
    /// to the library. Only meaningful while the window is split.
    func setPlayerFocused(_ focused: Bool) {
        guard isSplit, focused != isPlayerFocused, let geometry = appliedGeometry else { return }
        isPlayerFocused = focused
        playerLeading.constant = focused ? 0 : geometry.secondaryLeading
        if !focused { navigation.view.isHidden = false }
        player.setFocused(focused)
        let finish = { [weak self] in
            guard let self else { return }
            self.navigation.view.isHidden = self.isPlayerFocused
        }
        guard !UIAccessibility.isReduceMotionEnabled, view.window != nil else {
            view.layoutIfNeeded()
            finish()
            return
        }
        UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            self.view.layoutIfNeeded()
        } completion: { _ in finish() }
    }

    func setHasCurrentTrack(_ hasTrack: Bool) {
        hasCurrentTrack = hasTrack
        updateDockInset()
    }

    private func updateDockInset() {
        navigation.additionalSafeAreaInsets.bottom = (!isSplit && hasCurrentTrack) ? 72 : 0
    }

    private func applySplitLayout(_ geometry: AdaptiveLayout.SplitGeometry) {
        isSplit = true
        appliedGeometry = geometry
        navigationTrailing.isActive = false
        navigationWidth.constant = geometry.primaryWidth
        navigationWidth.isActive = true
        playerLeading.constant = isPlayerFocused ? 0 : geometry.secondaryLeading
        dimmingView.isHidden = true
        updateDockInset()
        player.setPaneMode(true)
    }

    private func applyCompactLayout() {
        isSplit = false
        appliedGeometry = nil
        navigationWidth.isActive = false
        navigationTrailing.isActive = true
        playerLeading.constant = 0
        let keepsExpanded = isPlayerFocused
        isPlayerFocused = false
        navigation.view.isHidden = false
        player.setFocused(false)
        dimmingView.isHidden = false
        updateDockInset()
        player.setPaneMode(false, keepsExpanded: keepsExpanded)
    }
}
