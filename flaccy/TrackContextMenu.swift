import UIKit

/// Shared context-menu builder so every place a track appears — library,
/// album, playlist, queue, now playing — offers the same rich set of actions.
/// Screens tailor it through `Context` (hide redundant navigation, drop
/// playback actions for the playing track, append screen-specific items).
enum TrackContextMenu {

    struct Context {
        var includeQueueActions = true
        var hideGoToAlbum = false
        var hideGoToArtist = false
        var hideLyrics = false
        var extraSections: [UIMenuElement] = []
    }

    static func build(
        for track: Track,
        in host: UIViewController & SonglinkShareable,
        push: @escaping (UIViewController) -> Void,
        context: Context = Context()
    ) -> UIMenu {
        var sections: [UIMenuElement] = []

        var playback: [UIMenuElement] = context.includeQueueActions ? queueActions(for: track, in: host) : []
        playback.append(stationAction(for: track, in: host))
        sections.append(UIMenu(options: .displayInline, children: playback))
        sections.append(UIMenu(options: .displayInline, children: collectionActions(for: track, in: host)))

        let navigation = navigationActions(for: track, in: host, push: push, context: context)
        if !navigation.isEmpty {
            sections.append(UIMenu(options: .displayInline, children: navigation))
        }
        sections.append(UIMenu(options: .displayInline, children: shareActions(for: track, in: host)))
        sections.append(contentsOf: context.extraSections)
        sections.append(UIMenu(options: .displayInline, children: [deleteAction(for: track, in: host)]))

        return UIMenu(title: track.qualityBadge ?? "", children: sections)
    }

    private static func deleteAction(for track: Track, in host: UIViewController) -> UIMenuElement {
        UIAction(title: "Delete from Library", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak host] _ in
            guard let host else { return }
            confirmDelete(
                title: "Delete \"\(track.title)\"?",
                message: "The audio file will be removed from this device.",
                in: host
            ) { [weak host] in
                Task { @MainActor in
                    await Library.shared.deleteTracks([track])
                    if let host {
                        ToastView.show("Deleted \(track.title)", in: host.view, style: .info)
                    }
                }
            }
        }
    }

    static func confirmDelete(title: String, message: String, in host: UIViewController, onConfirm: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            onConfirm()
        })
        host.present(alert, animated: true)
    }

    private static func queueActions(for track: Track, in host: UIViewController) -> [UIMenuElement] {
        [
            UIAction(title: "Play Next", image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { [weak host] _ in
                AudioPlayer.shared.insertNext(track)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if let host { ToastView.show("Playing next", in: host.view, style: .info) }
            },
            UIAction(title: "Add to Queue", image: UIImage(systemName: "text.append")) { [weak host] _ in
                AudioPlayer.shared.addToQueue(track)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if let host { ToastView.show("Added to queue", in: host.view, style: .info) }
            },
        ]
    }

    private static func stationAction(for track: Track, in host: UIViewController) -> UIMenuElement {
        UIAction(title: "Start Station", image: UIImage(systemName: "dot.radiowaves.left.and.right")) { [weak host] _ in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            AudioPlayer.shared.startStation(seedTrack: track)
            if let host { ToastView.show("Station started", in: host.view, style: .success) }
        }
    }

    private static func collectionActions(for track: Track, in host: UIViewController) -> [UIMenuElement] {
        let loved = LovedTracksService.shared.isLoved(track: track)
        let love = UIAction(
            title: loved ? "Unlove" : "Love",
            image: UIImage(systemName: loved ? "heart.slash" : "heart")
        ) { _ in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { await LovedTracksService.shared.toggleLove(track: track) }
        }

        let playlistMenu = UIMenu(
            title: "Add to Playlist",
            image: UIImage(systemName: "text.badge.plus"),
            children: [UIDeferredMenuElement.uncached { [weak host] completion in
                completion(playlistActions(for: track, in: host))
            }]
        )
        return [love, playlistMenu]
    }

    private static func playlistActions(for track: Track, in host: UIViewController?) -> [UIMenuElement] {
        let relativeURL = relativePath(for: track)
        var actions: [UIMenuElement] = []
        let playlists = (try? DatabaseManager.shared.fetchAllPlaylists()) ?? []
        for playlist in playlists {
            guard let playlistId = playlist.id else { continue }
            actions.append(UIAction(title: playlist.name, image: UIImage(systemName: "music.note.list")) { [weak host] _ in
                do {
                    try DatabaseManager.shared.addTrackToPlaylist(playlistId: playlistId, trackFileURL: relativeURL)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    if let host { ToastView.show("Added to \(playlist.name)", in: host.view, style: .success) }
                } catch {
                    AppLogger.error("Failed to add track to playlist: \(error.localizedDescription)", category: .database)
                    if let host { ToastView.show("Failed to add to playlist", in: host.view, style: .error) }
                }
            })
        }
        actions.append(UIAction(title: "New Playlist\u{2026}", image: UIImage(systemName: "plus")) { [weak host] _ in
            guard let host else { return }
            promptNewPlaylist(for: relativeURL, in: host)
        })
        return actions
    }

    private static func navigationActions(
        for track: Track,
        in host: UIViewController,
        push: @escaping (UIViewController) -> Void,
        context: Context
    ) -> [UIMenuElement] {
        var actions: [UIMenuElement] = []

        if !context.hideGoToAlbum,
           let album = Library.shared.albums.first(where: { $0.title == track.albumTitle && $0.artist == track.artist }) {
            actions.append(UIAction(title: "Go to Album", image: UIImage(systemName: "square.stack")) { _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                push(AlbumDetailViewController(album: album))
            })
        }

        if !context.hideGoToArtist {
            let artistAlbums = Library.shared.albums.filter { $0.artist == track.artist }
            if !artistAlbums.isEmpty {
                actions.append(UIAction(title: "Go to Artist", image: UIImage(systemName: "music.microphone")) { _ in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    push(ArtistDetailViewController(artistName: track.artist, albums: artistAlbums))
                })
            }
        }

        if !context.hideLyrics {
            actions.append(UIAction(title: "View Lyrics", image: UIImage(systemName: "text.quote")) { [weak host] _ in
                guard let host else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                presentLyrics(for: track, in: host)
            })
        }
        return actions
    }

    private static func shareActions(for track: Track, in host: UIViewController & SonglinkShareable) -> [UIMenuElement] {
        [
            UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak host] _ in
                guard let host else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                host.shareTrackViaSonglink(title: track.title, artist: track.artist, from: host.view)
            },
            UIAction(title: "Copy Song Info", image: UIImage(systemName: "doc.on.doc")) { [weak host] _ in
                UIPasteboard.general.string = "\(track.title) — \(track.artist)"
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if let host { ToastView.show("Copied", in: host.view, style: .info) }
            },
        ]
    }

    private static func presentLyrics(for track: Track, in host: UIViewController) {
        let lyrics = LyricsViewController(track: track.title, artist: track.artist, album: track.albumTitle)
        let container = UINavigationController(rootViewController: lyrics)
        lyrics.view.backgroundColor = .black
        lyrics.title = track.title
        container.overrideUserInterfaceStyle = .dark
        container.navigationBar.tintColor = .white
        lyrics.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak container] _ in container?.dismiss(animated: true) }
        )
        if let sheet = container.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        host.present(container, animated: true)
    }

    private static func promptNewPlaylist(for relativeURL: String, in host: UIViewController) {
        let alert = UIAlertController(title: "New Playlist", message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Playlist name"
            textField.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak host] _ in
            guard let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { return }
            do {
                let playlist = try DatabaseManager.shared.createPlaylist(name: name)
                if let playlistId = playlist.id {
                    try DatabaseManager.shared.addTrackToPlaylist(playlistId: playlistId, trackFileURL: relativeURL)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if let host { ToastView.show("Added to \(name)", in: host.view, style: .success) }
            } catch {
                AppLogger.error("Failed to create playlist: \(error.localizedDescription)", category: .database)
            }
        })
        host.present(alert, animated: true)
    }

    static func relativePath(for track: Track) -> String {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
        let trackPath = track.fileURL.standardizedFileURL.path
        let docsPath = docsDir.path
        guard trackPath.hasPrefix(docsPath) else { return track.fileURL.lastPathComponent }
        let rel = String(trackPath.dropFirst(docsPath.count))
        return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
    }
}
