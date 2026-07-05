import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private let playerContainer = PlayerContainerViewController()
    private var navController: UINavigationController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)

        let nav = UINavigationController(rootViewController: LibraryViewController())
        nav.navigationBar.prefersLargeTitles = false
        self.navController = nav

        let container = UIView()
        container.backgroundColor = .black
        container.addSubview(nav.view)
        nav.view.translatesAutoresizingMaskIntoConstraints = false

        let dimmingView = UIView()
        dimmingView.backgroundColor = .black
        dimmingView.alpha = 0
        dimmingView.isUserInteractionEnabled = false
        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dimmingView)

        playerContainer.onRequestPush = { [weak nav] vc in
            nav?.pushViewController(vc, animated: true)
        }
        playerContainer.onMorphProgress = { [weak dimmingView] t in
            dimmingView?.alpha = 0.35 * t
        }
        playerContainer.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(playerContainer.view)

        NSLayoutConstraint.activate([
            nav.view.topAnchor.constraint(equalTo: container.topAnchor),
            nav.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            nav.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            nav.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            dimmingView.topAnchor.constraint(equalTo: container.topAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            playerContainer.view.topAnchor.constraint(equalTo: container.topAnchor),
            playerContainer.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            playerContainer.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            playerContainer.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let rootVC = RootContainerViewController()
        rootVC.view = container
        rootVC.statusBarSource = playerContainer
        rootVC.addChild(nav)
        nav.didMove(toParent: rootVC)
        rootVC.addChild(playerContainer)
        playerContainer.didMove(toParent: rootVC)

        window.rootViewController = rootVC
        window.makeKeyAndVisible()
        self.window = window

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
    }

    @objc private func handlePaywallRequired() {
        guard let root = window?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        guard !(top is PaywallViewController) else { return }
        PaywallViewController.presentSheet(from: top)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
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
        navController?.additionalSafeAreaInsets.bottom = player.currentTrack != nil ? 72 : 0
    }
}

/// Root container that lets the player overlay drive the status bar, so it
/// flips to light content as the dark player expands over the library.
final class RootContainerViewController: UIViewController {
    weak var statusBarSource: UIViewController?

    override var childForStatusBarStyle: UIViewController? { statusBarSource }
}
