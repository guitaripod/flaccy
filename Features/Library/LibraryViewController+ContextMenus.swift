import Combine
import MidgarCore
import FlaccyCore
import UIKit
import UniformTypeIdentifiers

extension LibraryViewController {

    /// Opens the cover editor for a playlist once its tracks are resolved, so
    /// the sheet can offer the albums it draws from.
    func presentCoverEditor(for playlist: PlaylistItem) {
        Task { [weak self] in
            guard let self else { return }
            let tracks = await self.playlistAlbumIndex.tracks(forPlaylist: playlist.id)
            let subject = ArtworkSubject(playlistId: playlist.id, name: playlist.name, tracks: tracks)
            ArtworkEditorViewController.present(for: subject, from: self) { [weak self] in
                guard let self else { return }
                ToastView.show(String(localized: "Artwork updated"), in: self.view, style: .success)
            }
        }
    }

    func confirmAutomaticCover(for playlist: PlaylistItem) {
        let subject = ArtworkSubject(playlistId: playlist.id, name: playlist.name, tracks: [])
        ArtworkEditorViewController.confirmReset(for: subject, from: self, anchor: nil) { [weak self] in
            ArtworkEditorViewController.reset(subject) { [weak self] succeeded in
                guard succeeded, let self else { return }
                ToastView.show(String(localized: "Automatic cover restored"), in: self.view, style: .success)
            }
        }
    }

    func buildPlaylistContextMenu(for playlist: PlaylistItem) -> UIMenu {
        var actions = [UIAction(
            title: String(localized: "Edit Cover…"),
            image: UIImage(systemName: "photo")
        ) { [weak self] _ in
            self?.presentCoverEditor(for: playlist)
        }]
        let subject = ArtworkSubject(playlistId: playlist.id, name: playlist.name, tracks: [])
        if AlbumArtworkEditor.hasCustomCover(subject) {
            actions.append(UIAction(
                title: String(localized: "Use Automatic Cover"),
                image: UIImage(systemName: "arrow.uturn.backward")
            ) { [weak self] _ in
                self?.confirmAutomaticCover(for: playlist)
            })
        }
        return UIMenu(children: actions)
    }

    func presentSettings() {
        impactLight.impactOccurred()
        let settings = SettingsViewController()
        settings.onImportFiles = { [weak self] in
            self?.importTapped()
        }
        let nav = UINavigationController(rootViewController: settings)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    func importTapped() {
        impactLight.impactOccurred()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio, .folder])
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
        FunnelSignals.shared.noteAddMusicOpened()
    }

    func buildSongContextMenu(for track: Track) -> UIMenu {
        var context = TrackContextMenu.Context()
        context.otherCopies = viewModel.duplicateCopies[track.fileURL] ?? []
        return TrackContextMenu.build(
            for: track,
            in: self,
            push: { [weak self] viewController in
                self?.navigationController?.pushViewController(viewController, animated: true)
            },
            context: context
        )
    }

    func relativePath(for track: Track) -> String {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
        let trackPath = track.fileURL.standardizedFileURL.path
        guard trackPath.hasPrefix(docsDir.path) else { return track.fileURL.lastPathComponent }
        let rel = String(trackPath.dropFirst(docsDir.path.count))
        return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
    }

    func buildSuggestedPlaylistMenu(for suggestion: SuggestedPlaylist) -> UIMenu {
        let tracks = suggestion.tracks
        let play = UIAction(title: String(localized: "Play"), image: UIImage(systemName: "play.fill")) { _ in
            AudioPlayer.shared.play(tracks, startingAt: 0)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        let shuffle = UIAction(title: String(localized: "Shuffle"), image: UIImage(systemName: "shuffle")) { _ in
            AudioPlayer.shared.play(tracks.shuffled(), startingAt: 0)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        let playNext = UIAction(title: String(localized: "Play Next"), image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { _ in
            for track in tracks.reversed() { AudioPlayer.shared.insertNext(track) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        let addToQueue = UIAction(title: String(localized: "Add to Queue"), image: UIImage(systemName: "text.append")) { _ in
            for track in tracks { AudioPlayer.shared.addToQueue(track) }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        let save = UIAction(title: String(localized: "Save as Playlist"), image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
            self?.saveSuggestion(suggestion)
        }
        let saveMenu = UIMenu(options: .displayInline, children: [save])
        return UIMenu(children: [play, shuffle, playNext, addToQueue, saveMenu])
    }

    func saveSuggestion(_ suggestion: SuggestedPlaylist) {
        do {
            let playlist = try DatabaseManager.shared.createPlaylist(name: suggestion.title)
            if let id = playlist.id {
                for track in suggestion.tracks {
                    try DatabaseManager.shared.addTrackToPlaylist(playlistId: id, trackFileURL: relativePath(for: track))
                }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            viewModel.refreshPlaylists()
            ToastView.show(String(localized: "Saved \u{201C}\(suggestion.title)\u{201D}"), in: view, style: .success)
        } catch {
            MidgarLog.error("Failed to save suggested playlist: \(error.localizedDescription)", category: .database)
            ToastView.show(String(localized: "Couldn't create \u{201C}\(suggestion.title)\u{201D} — the library database couldn't be written. Check free disk space and try again."), in: view, style: .error)
        }
    }
}
