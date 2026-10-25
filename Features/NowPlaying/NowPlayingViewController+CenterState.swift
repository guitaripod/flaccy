import AVFoundation
import MidgarCore
import AVKit
import Combine
import UIKit

extension NowPlayingViewController {

    /// Switches the center region between the artwork column and in-place
    /// lyrics/queue content. States are exclusive; the lyrics and queue
    /// controllers are embedded as children.
    func setCenterState(_ target: CenterState) {
        guard target != centerState else { return }
        if target == .lyrics, AudioPlayer.shared.currentTrack == nil { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let previous = centerState
        centerState = target
        removeStateChild()
        if let child = makeStateChild(for: target) {
            embedStateChild(child)
        }
        updateStateCapsules()
        animateCenterTransition(from: previous, to: target)
        if layoutMode == .landscape { activateLayoutMode(.landscape, foldTop: nil, foldBottom: nil) }
        syncLaptopCompanions()
        if isPaneMode { onFocusRequest?(target != .artwork) }
        setupAccessibilityOrder()
        UIAccessibility.post(notification: .layoutChanged, argument: target == .artwork ? artworkContainer : compactHeader)
        MidgarLog.info("Now Playing center state -> \(target)", category: .ui)
    }

    func makeStateChild(for state: CenterState) -> UIViewController? {
        switch state {
        case .artwork:
            return nil
        case .lyrics:
            guard let track = AudioPlayer.shared.currentTrack else { return nil }
            return LyricsViewController(track: track.title, artist: track.artist, album: track.albumTitle)
        case .queue:
            let queueController = QueueViewController()
            queueController.onPushRequest = { [weak self] viewController in
                self?.dismissAndPush(viewController)
            }
            return queueController
        }
    }

    func embedStateChild(_ child: UIViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        stateContentContainer.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: stateContentContainer.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: stateContentContainer.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: stateContentContainer.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: stateContentContainer.bottomAnchor),
        ])
        child.didMove(toParent: self)
        stateChildController = child
    }

    func removeStateChild() {
        guard let child = stateChildController else { return }
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
        stateChildController = nil
    }

    func updateStateCapsules() {
        lyricsCapsule?.setActive(centerState == .lyrics, animated: hasAppliedInitialState)
        queueCapsule?.setActive(centerState == .queue, animated: hasAppliedInitialState)
        lyricsButton.tintColor = centerState == .lyrics ? .white : .white.withAlphaComponent(0.7)
        queueButton.tintColor = centerState == .queue ? .white : .white.withAlphaComponent(0.7)
        lyricsButton.accessibilityValue = centerState == .lyrics ? String(localized: "Shown") : nil
        updateQueueBadge()
    }

    /// Crossfade-and-scale morph between the artwork column and the compact
    /// header + child content; alpha-only under Reduce Motion.
    func animateCenterTransition(from previous: CenterState, to target: CenterState) {
        let showsArtwork = target == .artwork
        let keepsArtwork = showsArtwork || isFocusLayout
        artworkGroup.isUserInteractionEnabled = keepsArtwork
        compactHeader.isUserInteractionEnabled = !keepsArtwork
        stateContentContainer.isUserInteractionEnabled = !showsArtwork

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let apply = { [self] in
            artworkGroup.alpha = keepsArtwork ? 1 : 0
            compactHeader.alpha = keepsArtwork ? 0 : 1
            stateContentContainer.alpha = showsArtwork ? 0 : 1
            if !reduceMotion {
                artworkGroup.transform = keepsArtwork ? .identity : CGAffineTransform(scaleX: 0.94, y: 0.94)
                stateContentContainer.transform = showsArtwork
                    ? CGAffineTransform(translationX: 0, y: 12)
                    : .identity
            }
        }
        guard hasAppliedInitialState, !reduceMotion else {
            artworkGroup.transform = .identity
            stateContentContainer.transform = .identity
            apply()
            return
        }
        if !showsArtwork {
            stateContentContainer.alpha = 0
            stateContentContainer.transform = CGAffineTransform(translationX: 0, y: 12)
        }
        let animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.84, animations: apply)
        animator.startAnimation()
    }

    func navigateToArtist() {
        guard let track = AudioPlayer.shared.currentTrack else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let artistAlbums = Library.shared.albums.filter { $0.artist == track.artist }
        dismissAndPush(ArtistDetailViewController(artistName: track.artist, albums: artistAlbums))
    }

    func navigateToAlbum() {
        guard let track = AudioPlayer.shared.currentTrack,
              let album = Library.shared.albums.first(where: {
                  $0.title == track.albumTitle && $0.artist == track.artist
              })
        else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dismissAndPush(AlbumDetailViewController(album: album))
    }

    func dismissAndPush(_ viewController: UIViewController) {
        if let morphContainer {
            morphContainer.collapseAndPush(viewController)
            return
        }
        dismiss(animated: true) {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = scene.windows.first?.rootViewController,
                  let tabs = rootVC.children.compactMap({ $0 as? AppTabBarController }).first else { return }
            tabs.pushOnSelected(viewController)
        }
    }
}
