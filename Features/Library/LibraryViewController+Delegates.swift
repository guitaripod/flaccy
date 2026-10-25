import Combine
import MidgarCore
import FlaccyCore
import UIKit
import UniformTypeIdentifiers

extension LibraryViewController: UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        impactLight.impactOccurred()

        switch item {
        case .album(let album), .recentAlbum(let album):
            let detail = AlbumDetailViewController(album: album)
            navigationController?.pushViewController(detail, animated: true)
        case .song(let track):
            let queue = viewModel.visibleSongs
            AudioPlayer.shared.play(queue, startingAt: queue.firstIndex(of: track) ?? 0)
        case .artist(let artist):
            let albums = viewModel.albumsForArtist(artist.name)
            let vc = ArtistDetailViewController(
                artistName: artist.name, albums: albums.credited, appearsOn: albums.appearsOn
            )
            navigationController?.pushViewController(vc, animated: true)
        case .playlist(let playlist):
            let vc = PlaylistDetailViewController(playlistId: playlist.id, playlistName: playlist.name)
            navigationController?.pushViewController(vc, animated: true)
        case .suggestedPlaylist(let suggestion):
            guard !suggestion.tracks.isEmpty else { return }
            AudioPlayer.shared.play(suggestion.tracks, startingAt: 0)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            ToastView.show(String(localized: "Playing \(suggestion.title)"), in: view, style: .success)
        case .charts:
            let vc = ChartsViewController()
            navigationController?.pushViewController(vc, animated: true)
        case .wantlist:
            let vc = WantlistViewController()
            navigationController?.pushViewController(vc, animated: true)
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let item = dataSource.itemIdentifier(for: indexPath) else { return nil }

        switch item {
        case .album(let album), .recentAlbum(let album):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
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
                let shareAlbum = UIAction(title: String(localized: "Share"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    guard let self else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    self.shareAlbumViaSonglink(title: album.title, artist: album.artist, from: self.view)
                }
                let editArtwork = UIAction(title: String(localized: "Edit Artwork"), image: UIImage(systemName: "photo.badge.pencil")) { [weak self] _ in
                    guard let self else { return }
                    ArtworkEditorViewController.present(for: album, from: self) { [weak self] in
                        guard let self else { return }
                        ToastView.show(String(localized: "Artwork updated"), in: self.view, style: .success)
                    }
                }
                let shareMenu = UIMenu(options: .displayInline, children: [editArtwork, shareAlbum])
                let deleteAlbum = UIAction(title: String(localized: "Delete from Library"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    guard let self else { return }
                    TrackContextMenu.confirmDelete(
                        title: String(localized: "Delete \"\(album.title)\"?"),
                        message: String(localized: "All \(album.tracks.count) tracks will be removed from this device."),
                        in: self
                    ) { [weak self] in
                        Task { @MainActor in
                            await Library.shared.deleteTracks(album.tracks)
                            if let self {
                                ToastView.show(String(localized: "Deleted \(album.title)"), in: self.view, style: .info)
                            }
                        }
                    }
                }
                let deleteMenu = UIMenu(options: .displayInline, children: [deleteAlbum])
                return UIMenu(children: [playAction, shuffleAction, playNextAction, addToQueueAction, shareMenu, deleteMenu])
            }
        case .song(let track):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                self?.buildSongContextMenu(for: track)
            }
        case .suggestedPlaylist(let suggestion):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                self?.buildSuggestedPlaylistMenu(for: suggestion)
            }
        case .playlist(let playlist):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                self?.buildPlaylistContextMenu(for: playlist)
            }
        default:
            return nil
        }
    }
}

extension LibraryViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController is LibraryDebutSheetController else { return }
        noteDebutLeftScreen()
    }
}

extension LibraryViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            switch dataSource.itemIdentifier(for: indexPath) {
            case .album(let album), .recentAlbum(let album):
                AlbumArtworkCache.shared.preloadThumbnail(forAlbum: album.title, artist: album.artist)
            case .song(let track):
                AlbumArtworkCache.shared.preloadThumbnail(forAlbum: track.albumTitle, artist: track.artist)
            case .artist(let artist):
                if let album = viewModel.firstAlbum(forArtist: artist.name) {
                    AlbumArtworkCache.shared.preloadThumbnail(forAlbum: album.title, artist: album.artist)
                }
            default:
                break
            }
        }
    }
}

extension LibraryViewController: UISearchResultsUpdating {

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        viewModel.search(query: query)
    }
}

extension LibraryViewController: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else { return }
        let toast = ToastView.showLive(ImportOutcomeCopy.scanning, in: view)
        Task {
            let outcome = await viewModel.importFiles(
                from: urls,
                progress: { toast.update(ImportOutcomeCopy.progress($0)) },
                decideReplacements: { prompt in await ImportReplacementAlert.ask(prompt, from: self) }
            )
            let report = ImportOutcomeCopy.report(outcome)
            UINotificationFeedbackGenerator().notificationOccurred(report.isFailure ? .error : (report.isNoOp ? .warning : .success))
            toast.finish(report.message, style: report.isFailure ? .error : (report.isNoOp ? .info : .success))
        }
    }
}
