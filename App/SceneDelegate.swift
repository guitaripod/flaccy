import FlaccyCore
import UIKit
import MidgarCore

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private let playerContainer = PlayerContainerViewController()
    private var tabController: AppTabBarController?
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

        let tabs = AppTabBarController()
        self.tabController = tabs
        connectPlayer(to: tabs)

        let rootVC = RootContainerViewController(content: tabs, player: playerContainer)
        self.rootController = rootVC
        rootVC.onSplitChange = { [weak tabs] isSplit in tabs?.suppressesMiniPlayer = isSplit }
        tabs.library.debutHostProvider = { [weak rootVC] in rootVC?.view }

        window.overrideUserInterfaceStyle = AppAppearance.current.userInterfaceStyle
        window.rootViewController = rootVC
        window.makeKeyAndVisible()
        self.window = window
        RemoteLaunch.start()
        #if DEBUG
        RemoteExercise.runIfRequested()
        RemoteShot.runIfRequested(tabs: tabs)
        PaywallShot.runIfRequested(in: window)
        SampleExercise.runIfRequested()
        ReexportExercise.runIfRequested()
        NewMixShot.runIfRequested(tabs: tabs, player: playerContainer)
        WatchSyncExercise.runIfRequested()
        WatchRemoteExercise.runIfRequested()
        EqualizerExercise.runIfRequested()
        LyricShareExercise.runIfRequested()
        EqualizerShots.runIfRequested(in: window)
        #endif
        #if DEBUG && targetEnvironment(simulator)
        DemoRouter.runIfRequested(window: window, tabs: tabs, player: playerContainer)
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
            self, selector: #selector(entitlementsDidLoad), name: PurchaseManager.entitlementsDidLoad, object: nil
        )
        TrialReminderPrompt.observeOpportunities()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePlaybackUnavailable(_:)), name: RemoteAvailability.playbackUnavailable, object: nil
        )
        let launchLinks = connectionOptions.urlContexts.map(\.url)
        if !launchLinks.isEmpty {
            DispatchQueue.main.async { [weak self] in launchLinks.forEach { self?.openServerLink($0) } }
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        URLContexts.forEach { openServerLink($0.url) }
    }

    @objc private func handlePlaybackUnavailable(_ notification: Notification) {
        guard let message = notification.userInfo?[RemoteAvailability.messageKey] as? String,
              let top = TrialRunwayPresenter.topmostViewController(in: window) else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        ToastView.show(message, in: top.view, style: .error)
    }

    /// Opens the Add Server sheet filled in from a `flaccy://server` link; any other link is left alone.
    private func openServerLink(_ url: URL) {
        guard let link = ServerLink(url: url), let top = TrialRunwayPresenter.topmostViewController(in: window) else { return }
        MidgarLog.info("Opened a server link for \(link.name ?? "a server")", category: .ui)
        AddServerViewController.present(from: top, servers: RemoteServersViewModel(), link: link)
    }

    /// Wires the mini player to the tab controller: pushes land on the selected
    /// tab, and the dock either lives in the system's tab accessory (iOS 26) or
    /// floats just above the tab bar.
    private func connectPlayer(to tabs: AppTabBarController) {
        playerContainer.onRequestPush = { [weak tabs] viewController in
            tabs?.pushOnSelected(viewController)
        }
        tabs.onMiniPlayerTap = { [weak playerContainer] in playerContainer?.expand() }
        guard #available(iOS 26.0, *) else {
            playerContainer.dockObstruction = { [weak self, weak tabs] in
                guard let tabs, let space = self?.playerContainer.view else { return .zero }
                return tabs.barObstruction(in: space, safeArea: space.safeAreaInsets)
            }
            return
        }
        playerContainer.externalDockFrame = { [weak self, weak tabs] in
            guard let space = self?.playerContainer.view else { return nil }
            return tabs?.accessoryFrame(in: space)
        }
        playerContainer.onExternalDockHandoff = { [weak tabs] handedOff in
            tabs?.setAccessoryHandedOff(handedOff)
        }
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
        MidgarLog.info("Paywall deferred until the Debut dismisses", category: .purchases)
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

    @objc private func entitlementsDidLoad() {
        TrialRunwayPresenter.refresh(in: window)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        TrialRunwayPresenter.refresh(in: window)
        RemoteLaunch.becameActive()
        WatchSyncService.shared.resumeIfNeeded()
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
        tabController?.updateMiniPlayer(track: player.currentTrack, isPlaying: player.isPlaying)
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

    private let navigation: UIViewController
    private let player: PlayerContainerViewController
    private let dimmingView = UIView()
    private var navigationTrailing: NSLayoutConstraint!
    private var navigationWidth: NSLayoutConstraint!
    private var playerLeading: NSLayoutConstraint!
    private var appliedGeometry: AdaptiveLayout.SplitGeometry?
    private var hasCurrentTrack = false
    private(set) var isSplit = false {
        didSet {
            guard isSplit != oldValue else { return }
            onSplitChange?(isSplit)
        }
    }
    var onSplitChange: ((Bool) -> Void)?
    private var isPlayerFocused = false

    override var childForStatusBarStyle: UIViewController? { statusBarSource }

    #if canImport(UIKit, _version: 9127.0.85)
    @available(iOS 27.1, *)
    override var preferredVerticalBarBehavior: UIVerticalBarBehavior {
        isSplit ? .disabled : .automatic
    }
    #endif

    init(content navigation: UIViewController, player: PlayerContainerViewController) {
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
        raiseDebutAbovePlayer()
    }

    /// The Debut is added to this view while the content loads, before the
    /// player overlay exists; it has to end up above both.
    private func raiseDebutAbovePlayer() {
        guard let debut = view.subviews.first(where: { $0 is LibraryDebutView }) else { return }
        view.bringSubviewToFront(debut)
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

    /// Keeps scroll content clear of the floating dock. On iOS 26 the system's
    /// tab accessory reserves its own space, so nothing is added there.
    private func updateDockInset() {
        guard #unavailable(iOS 26.0) else { return }
        navigation.additionalSafeAreaInsets.bottom = (!isSplit && hasCurrentTrack) ? 68 : 0
    }

    private func applySplitLayout(_ geometry: AdaptiveLayout.SplitGeometry) {
        MidgarLog.debug(
            "Split layout: window \(view.bounds.size), division \(String(describing: view.divisionRegionFrame)), "
                + "primary \(geometry.primaryWidth), secondary at \(geometry.secondaryLeading)",
            category: .ui
        )
        isSplit = true
        appliedGeometry = geometry
        refreshVerticalBarConfiguration()
        navigationTrailing.isActive = false
        navigationWidth.constant = geometry.primaryWidth
        navigationWidth.isActive = true
        playerLeading.constant = isPlayerFocused ? 0 : geometry.secondaryLeading
        dimmingView.isHidden = true
        updateDockInset()
        player.setPaneMode(true)
    }

    private func refreshVerticalBarConfiguration() {
        #if canImport(UIKit, _version: 9127.0.85)
        if #available(iOS 27.1, *) { setNeedsUpdateOfVerticalBarConfiguration() }
        #endif
    }

    private func applyCompactLayout() {
        isSplit = false
        refreshVerticalBarConfiguration()
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
