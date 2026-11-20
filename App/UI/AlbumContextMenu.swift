import UIKit

/// The menu an album opens on a long press wherever it appears as a tile or a
/// row, so the Library and Search offer the same actions on the same release.
enum AlbumContextMenu {

    static func build(for album: Album, in host: UIViewController & SonglinkShareable) -> UIMenu {
        let playAction = UIAction(title: String(localized: "Play"), image: UIImage(systemName: "play.fill")) { _ in
            AudioPlayer.shared.play(album.tracks, startingAt: 0)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        let shuffleAction = UIAction(title: String(localized: "Shuffle"), image: UIImage(systemName: "shuffle")) { _ in
            var shuffled = album.tracks
            shuffled.shuffle()
            AudioPlayer.shared.play(shuffled, startingAt: 0)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        let playNextAction = UIAction(title: String(localized: "Play Next"), image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { _ in
            for track in album.tracks.reversed() {
                AudioPlayer.shared.insertNext(track)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        let addToQueueAction = UIAction(title: String(localized: "Add to Queue"), image: UIImage(systemName: "text.append")) { _ in
            for track in album.tracks {
                AudioPlayer.shared.addToQueue(track)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        let shareAlbum = UIAction(title: String(localized: "Share"), image: UIImage(systemName: "square.and.arrow.up")) { [weak host] _ in
            guard let host else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            host.shareAlbumViaSonglink(title: album.title, artist: album.artist, from: host.view)
        }
        let editArtwork = UIAction(title: String(localized: "Edit Artwork"), image: UIImage(systemName: "photo.badge.pencil")) { [weak host] _ in
            guard let host else { return }
            ArtworkEditorViewController.present(for: album, from: host) { [weak host] in
                guard let host else { return }
                ToastView.show(String(localized: "Artwork updated"), in: host.view, style: .success)
            }
        }
        let shareMenu = UIMenu(options: .displayInline, children: [editArtwork, shareAlbum])
        let localTracks = album.tracks.filter { $0.remoteSong == nil }
        let deleteAlbum = UIAction(title: String(localized: "Delete from Library"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak host] _ in
            guard let host else { return }
            TrackContextMenu.confirmDelete(
                title: String(localized: "Delete \"\(album.title)\"?"),
                message: String(localized: "All \(localTracks.count) tracks will be removed from this device."),
                in: host
            ) { [weak host] in
                Task { @MainActor in
                    await Library.shared.deleteTracks(localTracks)
                    if let host {
                        ToastView.show(String(localized: "Deleted \(album.title)"), in: host.view, style: .info)
                    }
                }
            }
        }
        var sections: [UIMenuElement] = [playAction, shuffleAction, playNextAction, addToQueueAction]
        if let download = RemoteDownloadActions.action(for: album.tracks, in: host) {
            sections.append(UIMenu(options: .displayInline, children: [download]))
        }
        sections.append(shareMenu)
        if !localTracks.isEmpty { sections.append(UIMenu(options: .displayInline, children: [deleteAlbum])) }
        return UIMenu(children: sections)
    }
}
