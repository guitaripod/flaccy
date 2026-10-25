import Foundation
import MidgarCore
import FlaccyCore

extension LibraryViewModel {

    /// Everything one query finds, grouped the way the Search tab lists it.
    struct SearchResults {
        var albums: [Album] = []
        var artists: [ArtistItem] = []
        var songs: [Track] = []
        var playlists: [PlaylistItem] = []

        var isEmpty: Bool {
            albums.isEmpty && artists.isEmpty && songs.isEmpty && playlists.isEmpty
        }
    }

    /// Albums, artists, songs and playlists matching `query`, through the same
    /// predicates the Library's own segments use and in the person's own sort
    /// order. Pure: it changes neither the segment nor the stored query.
    func searchResults(for query: String) -> SearchResults {
        let folded = Self.searchFold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !folded.isEmpty else { return SearchResults() }
        return SearchResults(
            albums: matchingAlbums(sortedAlbums, folded: folded),
            artists: matchingArtists(sortedArtists, folded: folded),
            songs: collapsingDuplicates(in: matchingSongs(sortedSongs, folded: folded)),
            playlists: matchingPlaylists(playlists, folded: folded)
        )
    }

    func matchingAlbums(_ albums: [Album], folded query: String) -> [Album] {
        guard !query.isEmpty else { return albums }
        return albums.filter {
            Self.searchFold($0.title).contains(query) || Self.searchFold($0.artist).contains(query)
        }
    }

    func matchingSongs(_ songs: [Track], folded query: String) -> [Track] {
        guard !query.isEmpty else { return songs }
        let keys = songSearchKeys()
        return songs.filter { track in
            if let key = keys[track.fileURL.absoluteString] { return key.contains(query) }
            return Self.searchFold("\(track.title)\n\(track.artist)\n\(track.albumTitle)").contains(query)
        }
    }

    func matchingArtists(_ artists: [ArtistItem], folded query: String) -> [ArtistItem] {
        guard !query.isEmpty else { return artists }
        return artists.filter { Self.searchFold($0.name).contains(query) }
    }

    func matchingPlaylists(_ playlists: [PlaylistItem], folded query: String) -> [PlaylistItem] {
        guard !query.isEmpty else { return playlists }
        return playlists.filter { Self.searchFold($0.name).contains(query) }
    }
}
