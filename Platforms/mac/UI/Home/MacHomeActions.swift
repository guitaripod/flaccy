import AppKit
import MidgarCore
import FlaccyCore
import FlaccyEngine

/// What Home does when something on it is used: start a queue under the right
/// name, open the thing, or put it out of Jump Back In.
enum MacHomeActions {

    static func context(for mix: SuggestedPlaylist) -> PlaybackContext {
        PlaybackContext(kind: .mix, id: mix.id, title: mix.title, subtitle: mix.subtitle)
    }

    static func ordered(_ album: Album) -> [Track] {
        TrackOrdering.ordered(
            album.tracks,
            number: { $0.trackNumber },
            path: { $0.fileURL.path },
            title: { $0.title }
        )
    }

    static func play(_ album: Album, shuffled: Bool) {
        let tracks = ordered(album)
        guard !tracks.isEmpty else { return }
        MidgarLog.info("Home playing album \(album.title) (shuffled: \(shuffled))", category: .playback)
        AudioPlayer.shared.play(shuffled ? tracks.shuffled() : tracks, startingAt: 0, context: HomeFeedBuilder.albumContext(album))
    }

    static func play(_ mix: SuggestedPlaylist, shuffled: Bool) {
        guard !mix.tracks.isEmpty else { return }
        MidgarLog.info("Home playing mix \(mix.title) (shuffled: \(shuffled))", category: .playback)
        AudioPlayer.shared.play(shuffled ? mix.tracks.shuffled() : mix.tracks, startingAt: 0, context: context(for: mix))
    }

    static func playNext(_ mix: SuggestedPlaylist, in window: NSWindow?) {
        guard !AudioPlayer.shared.queue.isEmpty else {
            play(mix, shuffled: false)
            return
        }
        for track in mix.tracks.reversed() {
            AudioPlayer.shared.insertNext(track)
        }
        MacToast.show(String(localized: "Playing \u{201C}\(mix.title)\u{201D} next"), style: .success, in: window)
    }

    static func addToQueue(_ mix: SuggestedPlaylist, in window: NSWindow?) {
        for track in mix.tracks {
            AudioPlayer.shared.addToQueue(track)
        }
        MacToast.show(String(localized: "Added \u{201C}\(mix.title)\u{201D} to queue"), style: .success, in: window)
    }

    static func play(playlist context: PlaybackContext, shuffled: Bool) {
        guard let id = Int64(context.id) else { return }
        let tracks = HomeFeedBuilder.playlistTracks(id: id, library: Library.shared.allTracks, database: .shared)
        guard !tracks.isEmpty else { return }
        MidgarLog.info("Home playing playlist \(context.title) (shuffled: \(shuffled))", category: .playback)
        AudioPlayer.shared.play(shuffled ? tracks.shuffled() : tracks, startingAt: 0, context: context)
    }

    static func playRadio(_ context: PlaybackContext) {
        guard context.id.hasPrefix("artist:") else {
            AudioPlayer.shared.playLibraryRadio()
            return
        }
        let folded = String(context.id.dropFirst("artist:".count))
        let name = Library.shared.allTracks.first { HomeKeys.fold($0.artist) == folded }?.artist ?? folded
        AudioPlayer.shared.startStation(seedArtist: name)
    }

    static func shuffleLibrary() {
        let pool = HideDuplicateSongsSetting.uniquePool(Library.shared.allTracks)
        guard !pool.isEmpty else { return }
        AudioPlayer.shared.play(pool.shuffled(), startingAt: 0)
    }

    static func play(_ item: HomeFeed.Item, shuffled: Bool, mixes: [SuggestedPlaylist]) {
        switch item.context.kind {
        case .album:
            if let album = item.coverAlbums.first { play(album, shuffled: shuffled) }
        case .playlist:
            play(playlist: item.context, shuffled: shuffled)
        case .mix:
            if let mix = mixes.first(where: { $0.id == item.context.id }) { play(mix, shuffled: shuffled) }
        case .radio:
            playRadio(item.context)
        case .queue:
            break
        }
    }

    static func open(_ item: HomeFeed.Item, mixes: [SuggestedPlaylist]) {
        switch item.context.kind {
        case .album:
            if let album = item.coverAlbums.first {
                LibraryNavigator.revealAlbum(title: album.title, artist: album.artist)
            }
        case .playlist:
            if let id = Int64(item.context.id) { LibraryNavigator.revealPlaylist(id: id) }
        case .mix, .radio, .queue:
            play(item, shuffled: false, mixes: mixes)
        }
    }

    static func showSection(_ section: SidebarSection) {
        NotificationCenter.default.post(
            name: .flaccyShowSection, object: nil,
            userInfo: [SectionNotificationKey.section: section.rawValue]
        )
    }

    static func openRecap() {
        NotificationCenter.default.post(name: .flaccyOpenRecapWeek, object: nil)
    }
}

extension Notification.Name {
    static let flaccyOpenRecapWeek = Notification.Name("flaccy.mac.openRecapWeek")
    static let flaccyRevealPlaylist = Notification.Name("flaccy.mac.revealPlaylist")
}

extension LibraryNavigator {

    static func revealPlaylist(id: Int64) {
        NotificationCenter.default.post(
            name: .flaccyRevealPlaylist, object: nil, userInfo: ["playlistID": id]
        )
    }
}
