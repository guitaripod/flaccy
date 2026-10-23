import AVFoundation
import MidgarCore
import AVKit
import Combine
import UIKit

extension NowPlayingViewController: UIGestureRecognizerDelegate {

    /// Restricts the track pan to strictly horizontally dominant drags,
    /// judged by accumulated translation (velocity is unreliable at
    /// recognition time), so vertical drags over the artwork always fall
    /// through to the container's collapse pan.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let translation = pan.translation(in: view)
        let drag = hypot(translation.x, translation.y) > 2 ? translation : pan.velocity(in: view)
        return abs(drag.x) > abs(drag.y)
    }
}

extension NowPlayingViewController: UIContextMenuInteractionDelegate {

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let track = AudioPlayer.shared.currentTrack else { return nil }
        if interaction.view === artworkContainer {
            return artworkContextMenuConfiguration(track: track)
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let copyTitle = UIAction(title: String(localized: "Copy Title"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = track.title
            }
            let copyArtist = UIAction(title: String(localized: "Copy Artist"), image: UIImage(systemName: "person")) { _ in
                UIPasteboard.general.string = track.artist
            }
            let copyBoth = UIAction(title: String(localized: "Copy Track Info"), image: UIImage(systemName: "music.note")) { _ in
                UIPasteboard.general.string = "\(track.artist) — \(track.title)"
            }
            return UIMenu(children: [copyTitle, copyArtist, copyBoth])
        }
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionAnimating?
    ) {
        guard interaction.view === artworkContainer else { return }
        artworkView.layer.removeAnimation(forKey: "tiltRelease")
        artworkView.layer.transform = CATransform3DIdentity
    }

    func artworkContextMenuConfiguration(track: Track) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var extras: [UIMenuElement] = []
            if let artwork = self.artworkView.image, self.artworkView.contentMode == .scaleAspectFill {
                extras.append(UIMenu(options: .displayInline, children: [
                    UIAction(title: String(localized: "Share Artwork"), image: UIImage(systemName: "photo")) { _ in
                        self.shareArtworkImage(artwork)
                    }
                ]))
            }
            return TrackContextMenu.build(
                for: track,
                in: self,
                push: { [weak self] viewController in
                    self?.dismissAndPush(viewController)
                },
                context: TrackContextMenu.Context(
                    includeQueueActions: false,
                    hideLyrics: true,
                    extraSections: extras
                )
            )
        }
    }
}
