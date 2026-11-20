import Foundation

/// Songs from the person's own library that fit a playlist, offered on a
/// shelf under its songs. Nothing is ever added on its own: a suggestion joins
/// the playlist only when the person adds it, and the shelf can be hidden.
///
/// A song fits by its artist: the playlist's own artists count by their share
/// of its songs, and artists Last.fm calls similar count by that share times
/// the match. A song from an album the playlist already draws on, a loved song
/// and a much-played one rank a little higher. Every artist's and album's
/// third song waits behind the other artists' and albums' first two, and so
/// on, so a page is never one album. Songs the playlist holds, by file or as
/// the same song from another release, are left out. The ranking is fixed for
/// the same input, and each page is the next `limit` of it, wrapping round. Mirrored in Rust as
/// `linux/shared/src/playlist_suggestions.rs`.
public enum PlaylistSuggestions {

    public static let pageSize = 8

    public static let perArtist = 2

    public static let perAlbum = 2

    public struct Song: Equatable, Sendable {
        public let file: String
        public let title: String
        public let artist: String
        public let album: String
        public let loved: Bool
        public let playCount: Int

        public init(file: String, title: String, artist: String, album: String, loved: Bool, playCount: Int) {
            self.file = file
            self.title = title
            self.artist = artist
            self.album = album
            self.loved = loved
            self.playCount = playCount
        }
    }

    public struct SimilarArtist: Equatable, Sendable {
        public let name: String
        public let match: Double

        public init(name: String, match: Double) {
            self.name = name
            self.match = match
        }
    }

    /// The playlist's artists by their share of its songs, most first, so a
    /// client knows whose similar artists to look up.
    public static func seedArtists(_ playlist: [Song], limit: Int) -> [String] {
        let shares = artistShares(playlist)
        let firstSeen = Dictionary(
            playlist.enumerated().map { (HomeKeys.fold($0.element.artist), $0.offset) }, uniquingKeysWith: min
        )
        let ordered = shares.keys.sorted {
            shares[$0]! != shares[$1]! ? shares[$0]! > shares[$1]! : firstSeen[$0]! < firstSeen[$1]!
        }
        return ordered.prefix(limit).compactMap { key in playlist.first { HomeKeys.fold($0.artist) == key }?.artist }
    }

    /// The files of page `page` of suggestions for `playlist`, drawn from
    /// `library`. `similar` maps a playlist artist, as any spelling the tags
    /// carry, to the artists Last.fm calls similar.
    public static func suggest(
        for playlist: [Song], library: [Song], similar: [String: [SimilarArtist]], page: Int = 0, limit: Int = pageSize
    ) -> [String] {
        let ranked = ranking(for: playlist, library: library, similar: similar)
        guard !ranked.isEmpty, limit > 0 else { return [] }
        let start = (max(page, 0) * limit) % ranked.count
        let end = min(start + limit, ranked.count)
        return Array(ranked[start..<end])
    }

    /// Every suggestion in order, before paging.
    public static func ranking(for playlist: [Song], library: [Song], similar: [String: [SimilarArtist]]) -> [String] {
        guard !playlist.isEmpty else { return [] }
        let shares = artistShares(playlist)
        var affinity = shares
        for (seed, matches) in similar {
            guard let share = shares[HomeKeys.fold(seed)] else { continue }
            for match in matches {
                let key = HomeKeys.fold(match.name)
                let weight = share * min(max(match.match, 0), 1) * 0.8
                affinity[key] = max(affinity[key] ?? 0, weight)
            }
        }
        let held = Set(playlist.map(\.file))
        var heldSongs = Set(playlist.map(songKey))
        let albums = Set(playlist.map(albumKey))
        var scored: [(file: String, song: Song, score: Double)] = []
        for song in library where !held.contains(song.file) {
            guard let weight = affinity[HomeKeys.fold(song.artist)], weight > 0 else { continue }
            var score = weight
            if albums.contains(albumKey(song)) { score += 0.15 }
            if song.loved { score += 0.2 }
            score += Double(min(max(song.playCount, 0), 50)) / 50 * 0.15
            scored.append((song.file, song, score))
        }
        scored.sort { left, right in
            left.score != right.score ? left.score > right.score : left.file.utf8.lexicographicallyPrecedes(right.file.utf8)
        }
        var perArtistCount: [String: Int] = [:]
        var perAlbumCount: [String: Int] = [:]
        var tiered: [(file: String, tier: Int)] = []
        for candidate in scored {
            guard heldSongs.insert(songKey(candidate.song)).inserted else { continue }
            let artist = HomeKeys.fold(candidate.song.artist)
            let album = albumKey(candidate.song)
            let tier = max(perArtistCount[artist, default: 0] / perArtist, perAlbumCount[album, default: 0] / perAlbum)
            perArtistCount[artist, default: 0] += 1
            perAlbumCount[album, default: 0] += 1
            tiered.append((candidate.file, tier))
        }
        return tiered.enumerated()
            .sorted { $0.element.tier != $1.element.tier ? $0.element.tier < $1.element.tier : $0.offset < $1.offset }
            .map(\.element.file)
    }

    private static func artistShares(_ playlist: [Song]) -> [String: Double] {
        var counts: [String: Int] = [:]
        for song in playlist { counts[HomeKeys.fold(song.artist), default: 0] += 1 }
        let total = Double(playlist.count)
        return counts.mapValues { Double($0) / total }
    }

    private static func songKey(_ song: Song) -> String {
        HomeKeys.fold(song.title) + HomeKeys.separator + HomeKeys.fold(song.artist)
    }

    private static func albumKey(_ song: Song) -> String {
        HomeKeys.fold(song.album) + HomeKeys.separator + HomeKeys.fold(song.artist)
    }
}
