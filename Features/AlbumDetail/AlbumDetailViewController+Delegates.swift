import FlaccyCore
import UIKit

extension AlbumDetailViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        impactLight.impactOccurred()
        audioPlayer.play(album.tracks, startingAt: indexPath.row)
    }

    /// Stretchy hero: pulling past the top scales the artwork card up around
    /// its center so the overscroll feels physical.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard hasAnimatedAppearance, !UIAccessibility.isReduceMotionEnabled,
              appliedHeaderStyle != .sideBySide else { return }
        let pull = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        if pull > 0 {
            let scale = 1 + min(pull / 500, 0.18)
            artworkCard.transform = CGAffineTransform(translationX: 0, y: -pull * 0.15).scaledBy(x: scale, y: scale)
        } else {
            artworkCard.transform = .identity
        }
    }

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let track = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let isLoved = LovedTracksService.shared.isLoved(track: track)
        let love = UIContextualAction(style: .normal, title: isLoved ? String(localized: "Unlove") : String(localized: "Love")) { [weak self] _, _, completion in
            guard let self else { return completion(false) }
            self.toggleLove(track)
            completion(true)
        }
        love.image = UIImage(systemName: isLoved ? "heart.slash.fill" : "heart.fill")
        love.backgroundColor = .systemPink
        let playNext = UIContextualAction(style: .normal, title: String(localized: "Play Next")) { [weak self] _, _, completion in
            guard let self else { return completion(false) }
            AudioPlayer.shared.insertNext(track)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ToastView.show(String(localized: "Playing next"), in: self.view, style: .info)
            completion(true)
        }
        playNext.image = UIImage(systemName: "text.line.first.and.arrowtriangle.forward")
        playNext.backgroundColor = .systemIndigo
        return UISwipeActionsConfiguration(actions: [love, playNext])
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let track = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let addToQueue = UIContextualAction(style: .normal, title: String(localized: "Queue")) { [weak self] _, _, completion in
            guard let self else { return completion(false) }
            AudioPlayer.shared.addToQueue(track)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ToastView.show(String(localized: "Added to queue"), in: self.view, style: .info)
            completion(true)
        }
        addToQueue.image = UIImage(systemName: "text.append")
        addToQueue.backgroundColor = .systemTeal
        return UISwipeActionsConfiguration(actions: [addToQueue])
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let track = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.buildTrackContextMenu(for: track)
        }
    }

    func buildTrackContextMenu(for track: Track) -> UIMenu {
        TrackContextMenu.build(
            for: track,
            in: self,
            push: { [weak self] viewController in
                self?.navigationController?.pushViewController(viewController, animated: true)
            },
            context: TrackContextMenu.Context(hideGoToAlbum: true)
        )
    }
}

extension AlbumDetailViewController: UIContextMenuInteractionDelegate {

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [self.editArtworkAction()])
        }
    }
}
