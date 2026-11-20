import FlaccyCore
import Foundation
import MidgarCore

/// Builds a playlist's Suggested Songs shelf off the main thread: the similar
/// artists of the playlist's five most frequent artists come from Last.fm's
/// cached lists (fetched once when missing, as a station does), and the
/// ranking is FlaccyCore's `PlaylistSuggestions`.
nonisolated enum PlaylistSuggestionLoader {

    static let seedArtistLimit = 5

    /// With `cachedOnly`, only similar-artist lists already cached count, so
    /// the shelf can show at once; the full pass fetches the missing lists,
    /// all at the same time.
    static func suggestions(for playlist: [Track], library: [Track], page: Int, cachedOnly: Bool = false) async -> [Track] {
        let songs = playlist.map(song)
        guard !songs.isEmpty else { return [] }
        let seeds = PlaylistSuggestions.seedArtists(songs, limit: seedArtistLimit)
        let similar = await withTaskGroup(of: (String, [PlaylistSuggestions.SimilarArtist]).self) { group in
            for seed in seeds {
                group.addTask {
                    let matches = await SimilarArtistService.shared.similarArtistsInLibrary(toArtist: seed, cachedOnly: cachedOnly)
                    return (seed, matches.map { PlaylistSuggestions.SimilarArtist(name: $0.name, match: $0.match) })
                }
            }
            var found: [String: [PlaylistSuggestions.SimilarArtist]] = [:]
            for await (seed, matches) in group { found[seed] = matches }
            return found
        }
        let byFile = Dictionary(library.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let files = PlaylistSuggestions.suggest(for: songs, library: library.map(song), similar: similar, page: page)
        MidgarLog.debug("Playlist suggestions page \(page): \(files.count) of a \(library.count)-song library", category: .ui)
        return files.compactMap { byFile[$0] }
    }

    private static func key(_ track: Track) -> String {
        track.fileURL.absoluteString
    }

    private static func song(_ track: Track) -> PlaylistSuggestions.Song {
        PlaylistSuggestions.Song(
            file: key(track), title: track.title, artist: track.artist, album: track.albumTitle,
            loved: track.loved, playCount: track.playCount
        )
    }
}

/// Whether playlists show their Suggested Songs shelf on this device. On by
/// default; one switch for every playlist, from any playlist's menu.
nonisolated enum PlaylistSuggestionsSetting {

    static let didChange = Notification.Name("flaccy.playlistSuggestions.didChange")

    private static let hiddenKey = "flaccy.playlistSuggestions.hidden"

    static var isShown: Bool { !UserDefaults.standard.bool(forKey: hiddenKey) }

    static func setShown(_ shown: Bool) {
        UserDefaults.standard.set(!shown, forKey: hiddenKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
