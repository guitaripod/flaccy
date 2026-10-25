import FlaccyCore
import MidgarCore
import UIKit

extension HomeViewController {

    private var player: AudioPlaying { AudioPlayer.shared }

    func handle(hero action: HomeHeroAction) {
        let feed = model.feed
        switch action {
        case .resume: resume()
        case .shuffleResume: shuffleResume()
        case .goToContext: openContext(feed.resume?.context, album: feed.resume?.album)
        case .playFromBeginning: playFromBeginning()
        case .playMix: feed.upNext.map { play(mix: $0.mix, shuffled: false) }
        case .playMixNext: feed.upNext.map { playNext(mix: $0.mix) }
        case .shuffleMix: feed.upNext.map { play(mix: $0.mix, shuffled: true) }
        case .shuffleLibrary: shuffleLibrary()
        case .libraryRadio: player.playLibraryRadio()
        }
    }

    func handle(empty action: HomeEmptyAction) {
        let library = self.library
        switch action {
        case .addMusic: library.performWhenVisible { library.importTapped() }
        case .addSample: library.performWhenVisible { library.sampleMusicTapped() }
        case .computerGuide: library.performWhenVisible { library.presentComputerTransferGuide() }
        }
    }

    private func resume() {
        guard !player.queue.isEmpty else {
            if let resume = model.feed.resume { playContext(resume.context, shuffled: false) }
            return
        }
        if !player.isPlaying { player.togglePlayPause() }
    }

    private func shuffleResume() {
        guard let resume = model.feed.resume else { return }
        if resume.context.kind == .queue || resume.context.kind == .radio {
            guard !player.queue.isEmpty else { return }
            player.play(player.queue.shuffled(), startingAt: 0, context: resume.context)
            return
        }
        playContext(resume.context, shuffled: true)
    }

    private func playFromBeginning() {
        guard !player.queue.isEmpty else { return }
        player.play(player.queue, startingAt: 0, context: player.playbackContext)
    }

    private func shuffleLibrary() {
        let tracks = HideDuplicateSongsSetting.uniquePool(Library.shared.allTracks).shuffled()
        guard !tracks.isEmpty else { return }
        player.play(tracks, startingAt: 0)
    }

    func play(mix: SuggestedPlaylist, shuffled: Bool) {
        guard !mix.tracks.isEmpty else { return }
        let context = PlaybackContext(kind: .mix, id: mix.id, title: mix.title, subtitle: mix.subtitle)
        player.play(shuffled ? mix.tracks.shuffled() : mix.tracks, startingAt: 0, context: context)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func playNext(mix: SuggestedPlaylist) {
        guard !mix.tracks.isEmpty else { return }
        for track in mix.tracks.reversed() { player.insertNext(track) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        ToastView.show(HomeCopy.playingNext, in: view, style: .success)
    }

    /// Starts the album, playlist, mix or radio a Jump Back In entry names.
    func playContext(_ context: PlaybackContext, shuffled: Bool) {
        switch context.kind {
        case .radio:
            startRadio(context)
        case .mix:
            if context.id == "crate-dig" {
                player.playCrateDig()
            } else if let mix = model.feed.mixes.first(where: { $0.id == context.id }) {
                play(mix: mix, shuffled: shuffled)
            }
        case .album:
            guard let album = model.feed.jumpBackIn.first(where: { $0.context == context })?.coverAlbums.first
                ?? model.feed.resume?.album else { return }
            start(album.tracks, context: context, shuffled: shuffled)
        case .playlist:
            guard let id = Int64(context.id) else { return }
            let tracks = HomeFeedBuilder.playlistTracks(id: id, library: Library.shared.allTracks, database: .shared)
            start(tracks, context: context, shuffled: shuffled)
        case .queue:
            break
        }
    }

    private func start(_ tracks: [Track], context: PlaybackContext, shuffled: Bool) {
        guard !tracks.isEmpty else { return }
        player.play(shuffled ? tracks.shuffled() : tracks, startingAt: 0, context: context)
    }

    private func startRadio(_ context: PlaybackContext) {
        guard context.id.hasPrefix("artist:") else {
            player.playLibraryRadio()
            return
        }
        let key = String(context.id.dropFirst("artist:".count))
        let seed = Library.shared.allTracks.first { HomeKeys.fold($0.artist) == key }?.artist ?? key
        player.startStation(seedArtist: seed)
    }

    func openContext(_ context: PlaybackContext?, album: Album?) {
        guard let context else { return }
        switch context.kind {
        case .album:
            guard let album else { return }
            navigationController?.pushViewController(AlbumDetailViewController(album: album), animated: true)
        case .playlist:
            guard let id = Int64(context.id) else { return }
            navigationController?.pushViewController(
                PlaylistDetailViewController(playlistId: id, playlistName: context.title), animated: true
            )
        default:
            break
        }
    }

    func select(_ item: HomeItem) {
        let feed = model.feed
        switch item {
        case .jump(let context):
            let entry = feed.jumpBackIn.first { $0.context == context }
            switch context.kind {
            case .album, .playlist: openContext(context, album: entry?.coverAlbums.first)
            default: playContext(context, shuffled: false)
            }
        case .mix(let id):
            if let mix = feed.mixes.first(where: { $0.id == id }) { play(mix: mix, shuffled: false) }
        case .libraryRadio:
            player.playLibraryRadio()
        case .recent(let id):
            if let album = feed.recentlyAdded.first(where: { $0.id == id }) {
                navigationController?.pushViewController(AlbumDetailViewController(album: album), animated: true)
            }
        case .memory:
            guard let memory = feed.onThisDay else { return }
            let context = HomeFeedBuilder.albumContext(memory.album)
            start(memory.album.tracks, context: context, shuffled: false)
        case .week:
            tabController?.show(.recap)
        default:
            break
        }
    }

    func contextMenu(for item: HomeItem) -> UIMenu? {
        let feed = model.feed
        switch item {
        case .jump(let context):
            return UIMenu(children: [
                UIAction(title: HomeCopy.play, image: UIImage(systemName: "play.fill")) { [weak self] _ in
                    self?.playContext(context, shuffled: false)
                },
                UIAction(title: HomeCopy.shuffle, image: UIImage(systemName: "shuffle")) { [weak self] _ in
                    self?.playContext(context, shuffled: true)
                },
                UIAction(
                    title: HomeCopy.removeFromJumpBackIn, image: UIImage(systemName: "minus.circle"),
                    attributes: .destructive
                ) { _ in
                    RecentContextStore.shared.remove(key: context.key)
                },
            ])
        case .mix(let id):
            guard let mix = feed.mixes.first(where: { $0.id == id }) else { return nil }
            return UIMenu(children: [
                UIAction(title: HomeCopy.play, image: UIImage(systemName: "play.fill")) { [weak self] _ in
                    self?.play(mix: mix, shuffled: false)
                },
                UIAction(title: HomeCopy.shuffle, image: UIImage(systemName: "shuffle")) { [weak self] _ in
                    self?.play(mix: mix, shuffled: true)
                },
            ])
        case .recent(let id):
            guard let album = feed.recentlyAdded.first(where: { $0.id == id }) else { return nil }
            let context = HomeFeedBuilder.albumContext(album)
            return UIMenu(children: [
                UIAction(title: HomeCopy.play, image: UIImage(systemName: "play.fill")) { [weak self] _ in
                    self?.start(album.tracks, context: context, shuffled: false)
                },
                UIAction(title: HomeCopy.shuffle, image: UIImage(systemName: "shuffle")) { [weak self] _ in
                    self?.start(album.tracks, context: context, shuffled: true)
                },
            ])
        default:
            return nil
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .jump, .mix, .libraryRadio, .recent, .memory, .week: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        select(item)
    }

    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let item = dataSource.itemIdentifier(for: indexPath),
              let menu = contextMenu(for: item) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}
