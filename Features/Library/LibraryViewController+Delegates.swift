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
                let localTracks = album.tracks.filter { $0.remoteSong == nil }
                let deleteAlbum = UIAction(title: String(localized: "Delete from Library"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    guard let self else { return }
                    TrackContextMenu.confirmDelete(
                        title: String(localized: "Delete \"\(album.title)\"?"),
                        message: String(localized: "All \(localTracks.count) tracks will be removed from this device."),
                        in: self
                    ) { [weak self] in
                        Task { @MainActor in
                            await Library.shared.deleteTracks(localTracks)
                            if let self {
                                ToastView.show(String(localized: "Deleted \(album.title)"), in: self.view, style: .info)
                            }
                        }
                    }
                }
                var sections: [UIMenuElement] = [playAction, shuffleAction, playNextAction, addToQueueAction]
                if let self, let download = RemoteDownloadActions.action(for: album.tracks, in: self) {
                    sections.append(UIMenu(options: .displayInline, children: [download]))
                }
                sections.append(shareMenu)
                if !localTracks.isEmpty { sections.append(UIMenu(options: .displayInline, children: [deleteAlbum])) }
                return UIMenu(children: sections)
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
        importFiles(at: urls)
    }

    /// Closing the picker with nothing chosen and no music of their own means the person did not find their music in
    /// Files, so the ways it does get in are offered once a launch.
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        FunnelSignals.shared.notePickerCancelled()
        guard !libraryHoldsOwnMusic, !ImportHelpViewController.offeredAfterCancel else { return }
        ImportHelpViewController.noteOfferedAfterCancel()
        presentImportHelp(reason: nil)
    }

    /// Imports files picked in Files or dropped on the window, reporting
    /// progress and the outcome in `host` (the Library when nil) and running
    /// `finished` once the import has let go of the files.
    func importFiles(at urls: [URL], reportingIn host: UIView? = nil, finished: (@MainActor () -> Void)? = nil) {
        guard !urls.isEmpty else {
            finished?()
            return
        }
        let toast = ToastView.showLive(ImportOutcomeCopy.scanning, in: host ?? view)
        let presenter: UIViewController = view.window != nil ? self : (host?.window?.rootViewController ?? self)
        Task {
            let outcome = await viewModel.importFiles(
                from: urls,
                progress: { toast.update(ImportOutcomeCopy.progress($0)) },
                decideReplacements: { prompt in await ImportReplacementAlert.ask(prompt, from: presenter) }
            )
            finished?()
            await Self.untilActive()
            presentImportReport(ImportOutcomeCopy.report(outcome), closing: toast, in: host ?? view)
        }
    }

    /// Says how the import ended. A pick that added nothing gets the reason and the ways music does get in: the whole
    /// help when the library has no music of its own yet, otherwise a toast that opens it.
    private func presentImportReport(_ report: ImportOutcomeCopy.Report, closing toast: ToastView.Live, in host: UIView) {
        UINotificationFeedbackGenerator().notificationOccurred(report.isFailure ? .error : (report.isNoOp ? .warning : .success))
        guard report.isDeadEnd else {
            toast.finish(report.message, style: report.isFailure ? .error : (report.isNoOp ? .info : .success))
            return
        }
        guard libraryHoldsOwnMusic else {
            toast.dismiss()
            presentImportHelp(reason: report.message)
            return
        }
        toast.dismiss()
        ToastView.showAction(report.message, actionTitle: String(localized: "Help"), in: host, style: .info) { [weak self] in
            self?.presentImportHelp(reason: report.message)
        }
    }

    /// An import can finish while the app is in the background, carried by its continued processing task; its result
    /// waits until the person is back to read it.
    private static func untilActive() async {
        guard UIApplication.shared.applicationState != .active else { return }
        for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
            return
        }
    }

    var libraryHoldsOwnMusic: Bool {
        let sampleNames = SampleMusicService.sampleFileNames
        return Library.shared.allTracks.contains { !SampleMusicService.isSample($0.fileURL, among: sampleNames) }
    }

    /// Opens the help over the Library, bringing the Library forward first when an iPad drop finished elsewhere, so
    /// every way in it offers starts from where music lands.
    func presentImportHelp(reason: String?) {
        performWhenVisible { [weak self] in self?.showImportHelpSheet(reason: reason) }
    }

    /// Presents over whatever already sits on the Library, once a sheet on its way out (the Files picker) has gone.
    private func showImportHelpSheet(reason: String?) {
        var host: UIViewController = self
        while let presented = host.presentedViewController {
            guard !presented.isBeingDismissed else {
                if let transition = presented.transitionCoordinator {
                    transition.animate(alongsideTransition: nil) { [weak self] _ in self?.showImportHelpSheet(reason: reason) }
                } else {
                    DispatchQueue.main.async { [weak self] in self?.showImportHelpSheet(reason: reason) }
                }
                return
            }
            host = presented
        }
        let offersSample = !SampleMusicService.shared.isDownloading && !Library.shared.allTracks.contains {
            SampleMusicService.isSample($0.fileURL)
        }
        let help = ImportHelpViewController.sheet(reason: reason, offersSample: offersSample) { [weak self] action in
            self?.carryOut(action)
        }
        host.present(help, animated: true)
    }

    /// The help may have opened over another sheet the Library had up; that sheet goes first, so the way in the person
    /// chose is presented from the Library itself.
    private func carryOut(_ action: ImportHelpViewController.Action) {
        guard presentedViewController == nil else {
            dismiss(animated: true) { [weak self] in self?.carryOut(action) }
            return
        }
        switch action {
        case .chooseFiles: importTapped()
        case .wifiTransfer: presentWiFiTransfer()
        case .musicServer: AddServerViewController.present(from: self, servers: RemoteServersViewModel())
        case .sample: sampleMusicTapped()
        }
    }
}
