import Foundation

/// Finds artists similar to a seed artist that already exist in the local
/// library, using `artist.getSimilar` intersected with local artists and
/// weighted by Last.fm match score. Similar lists are cached for 30 days.
nonisolated final class SimilarArtistService: @unchecked Sendable {

    static let shared = SimilarArtistService()

    private let db = DatabaseManager.shared
    private let lastFM = LastFMService.shared
    private let cacheLifetime: TimeInterval = 30 * 24 * 3600

    private init() {}

    /// Similar-artist names present in the library, ordered by match strength.
    func similarArtistsInLibrary(toArtist artist: String) async -> [(name: String, match: Double)] {
        let similar = await cachedSimilar(artist: artist)
        guard !similar.isEmpty else { return [] }

        let libraryArtists = (try? db.fetchLibraryArtists()) ?? []
        var byLowercased: [String: String] = [:]
        for name in libraryArtists { byLowercased[name.lowercased()] = name }

        return similar.compactMap { entry in
            guard let localName = byLowercased[entry.name.lowercased()] else { return nil }
            return (name: localName, match: entry.match)
        }
    }

    /// Albums by similar artists present in the library, ordered by match.
    func similarInLibrary(toArtist artist: String) async -> [Album] {
        let matches = await similarArtistsInLibrary(toArtist: artist)
        guard !matches.isEmpty else { return [] }

        var rank: [String: Double] = [:]
        for match in matches { rank[match.name.lowercased()] = match.match }

        let grouped = (try? db.fetchAlbumsWithTracksLightweight()) ?? []
        var albums: [(album: Album, match: Double)] = []
        for group in grouped {
            guard let first = group.tracks.first,
                  let weight = rank[first.artist.lowercased()] else { continue }
            let tracks = group.tracks.map { Track.from(light: $0, artwork: nil) }
            let album = Album(
                title: first.albumTitle,
                artist: first.artist,
                artwork: nil,
                tracks: tracks,
                year: group.album?.year,
                genre: group.album?.genre
            )
            albums.append((album, weight))
        }
        return albums.sorted { $0.match > $1.match }.map(\.album)
    }

    private func cachedSimilar(artist: String) async -> [(name: String, match: Double)] {
        let fresherThan = Date().addingTimeInterval(-cacheLifetime)
        if let cached = try? db.fetchCachedSimilarArtists(artist: artist, fresherThan: fresherThan), !cached.isEmpty {
            return cached.map { (name: $0.similarName, match: $0.match) }
        }

        let fetched = await lastFM.fetchSimilarArtists(artist: artist, limit: 100)
        if !fetched.isEmpty {
            try? db.saveSimilarArtists(artist: artist, entries: fetched)
        }
        return fetched
    }
}
