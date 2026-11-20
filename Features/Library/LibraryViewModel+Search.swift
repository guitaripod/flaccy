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

    /// Albums, artists, songs and playlists matching `query` by the shared
    /// search rules, each kind ordered by how well its name answers the query
    /// and, between equal answers, in the person's own sort order. Pure: it
    /// changes neither the segment nor the stored query.
    func searchResults(for query: String) -> SearchResults {
        let words = LibrarySearch.Query(query)
        guard !words.isEmpty else { return SearchResults() }
        return SearchResults(
            albums: Self.bestFirst(matchingAlbums(sortedAlbums, query: words)) {
                words.rank(name: $0.title, other: [$0.artist])
            },
            artists: Self.bestFirst(matchingArtists(sortedArtists, query: words)) { words.rank(name: $0.name) },
            songs: Self.bestFirst(collapsingDuplicates(in: matchingSongs(sortedSongs, query: words))) {
                Self.songRank($0, for: words)
            },
            playlists: Self.bestFirst(matchingPlaylists(playlists, query: words)) { words.rank(name: $0.name) }
        )
    }

    /// How well a song answers a query. A title that is the query, or begins
    /// with it, comes first; past that a word somewhere in the title says no
    /// more than the artist or the album matching, so those are one group.
    private static func songRank(_ track: Track, for query: LibrarySearch.Query) -> LibrarySearch.Rank? {
        guard let rank = query.rank(name: track.title, other: [track.artist, track.albumTitle]) else { return nil }
        return rank > .prefix ? .elsewhere : rank
    }

    /// `rows` with the best answers first, keeping the order they came in
    /// between rows that answer equally well.
    private static func bestFirst<Row>(_ rows: [Row], rank: (Row) -> LibrarySearch.Rank?) -> [Row] {
        rows.enumerated()
            .map { (rank: rank($0.element) ?? .elsewhere, index: $0.offset, row: $0.element) }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.row)
    }

    func matchingAlbums(_ albums: [Album], query: LibrarySearch.Query) -> [Album] {
        guard !query.isEmpty else { return albums }
        return albums.filter { query.matches(fields: [$0.title, $0.artist]) }
    }

    func matchingSongs(_ songs: [Track], query: LibrarySearch.Query) -> [Track] {
        guard !query.isEmpty else { return songs }
        let keys = songSearchKeys()
        return songs.filter { track in
            if let key = keys[track.fileURL.absoluteString] { return query.matches(haystack: key) }
            return query.matches(fields: [track.title, track.artist, track.albumTitle])
        }
    }

    func matchingArtists(_ artists: [ArtistItem], query: LibrarySearch.Query) -> [ArtistItem] {
        guard !query.isEmpty else { return artists }
        return artists.filter { query.matches(fields: [$0.name]) }
    }

    func matchingPlaylists(_ playlists: [PlaylistItem], query: LibrarySearch.Query) -> [PlaylistItem] {
        guard !query.isEmpty else { return playlists }
        return playlists.filter { query.matches(fields: [$0.name]) }
    }
}
