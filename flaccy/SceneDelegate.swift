import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private let miniPlayer = MiniPlayerView()
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
        container.addSubview(nav.view)
        nav.view.translatesAutoresizingMaskIntoConstraints = false

        miniPlayer.translatesAutoresizingMaskIntoConstraints = false
        miniPlayer.isHidden = true
        miniPlayer.onTap = { [weak self] in self?.presentNowPlaying() }
        container.addSubview(miniPlayer)

        NSLayoutConstraint.activate([
            nav.view.topAnchor.constraint(equalTo: container.topAnchor),
            nav.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            nav.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            nav.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            miniPlayer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            miniPlayer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            miniPlayer.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            miniPlayer.heightAnchor.constraint(equalToConstant: 56),
        ])

        let rootVC = UIViewController()
        rootVC.view = container
        rootVC.addChild(nav)
        nav.didMove(toParent: rootVC)

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
    }

    private func presentNowPlaying() {
        guard let nav = navController else { return }
        let vc = NowPlayingViewController()
        vc.modalPresentationStyle = .pageSheet
        nav.present(vc, animated: true)
    }

    @objc private func handleQueueTapped() {
        guard let nav = navController else { return }
        let queueVC = QueueViewController()
        let queueNav = UINavigationController(rootViewController: queueVC)
        queueNav.modalPresentationStyle = .pageSheet
        nav.present(queueNav, animated: true)
    }

    @objc private func trackDidChange() {
        updateMiniPlayer()
    }

    @objc private func playbackStateDidChange() {
        updateMiniPlayer()
    }

    private func updateMiniPlayer() {
        let player = AudioPlayer.shared
        if let track = player.currentTrack {
            miniPlayer.configure(with: track, isPlaying: player.isPlaying)
            if miniPlayer.isHidden {
                miniPlayer.isHidden = false
                miniPlayer.alpha = 0
                UIView.animate(withDuration: 0.3) { self.miniPlayer.alpha = 1 }
            }
            navController?.additionalSafeAreaInsets.bottom = 72
        } else {
            if !miniPlayer.isHidden {
                UIView.animate(withDuration: 0.2, animations: {
                    self.miniPlayer.alpha = 0
                }) { _ in
                    self.miniPlayer.isHidden = true
                }
            }
            navController?.additionalSafeAreaInsets.bottom = 0
        }
    }
}
