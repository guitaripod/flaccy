import Combine
import MidgarCore
import FlaccyCore

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension LibraryViewModel {

    func albumDateAddedMap() -> [String: Date] {
        if let cached = cachedAlbumAdded { return cached }
        var map = [String: Date]()
        for album in library.albums {
            var newest = Date.distantPast
            for track in album.tracks {
                if let added = meta(for: track)?.dateAdded, added > newest { newest = added }
            }
            map["\(album.title)|\(album.artist)"] = newest
        }
        cachedAlbumAdded = map
        return map
    }

    func albumLastPlayedMap() -> [String: Date] {
        if let cached = cachedAlbumPlayed { return cached }
        var map = [String: Date]()
        if let rows = try? DatabaseManager.shared.lastPlayedByAlbum() {
            for row in rows { map["\(row.albumTitle)|\(row.artist)"] = row.lastPlayed }
        }
        cachedAlbumPlayed = map
        return map
    }

    func qualityRank(_ track: Track) -> Int {
        (track.isLossless ? 1 << 24 : 0) + (track.bitDepth ?? 0) * 100000 + (track.sampleRate ?? 0)
    }

    func isLovedAlbum(_ album: Album) -> Bool {
        LovedTracksService.shared.containsLoved(among: album.tracks)
    }

    /// Albums highly played but not spun recently, ranked by a Longplay-style
    /// negligence score of playCount over days since last play.
    var rediscover: (keys: Set<String>, albums: [Album]) {
        if let cached = cachedRediscover { return cached }
        var scored: [(key: String, score: Double)] = []
        if let rows = try? DatabaseManager.shared.lastPlayedByAlbum() {
            let now = Date()
            for row in rows {
                let days = Int(now.timeIntervalSince(row.lastPlayed) / 86400)
                guard days >= rediscoverMinDays, row.playCount >= rediscoverMinPlays else { continue }
                let score = Double(row.playCount) / Double(days + 1)
                scored.append((key: "\(row.albumTitle)|\(row.artist)", score: score))
            }
        }
        scored.sort { $0.score > $1.score }
        let byKey = Dictionary(library.albums.map { ("\($0.title)|\($0.artist)", $0) }, uniquingKeysWith: { a, _ in a })
        let albums = scored.compactMap { byKey[$0.key] }
        let result = (keys: Set(scored.map(\.key)), albums: albums)
        cachedRediscover = result
        return result
    }

    var sortedAlbums: [Album] {
        cacheLock.lock()
        if let cached = cachedSortedAlbums {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let result: [Album]
        switch albumSort {
        case .title:
            result = library.albums.sorted { Self.titleOrder($0.title, $1.title) }
        case .artist:
            result = library.albums.sorted {
                let cmp = $0.artist.caseInsensitiveCompare($1.artist)
                return cmp == .orderedSame ? Self.titleOrder($0.title, $1.title) : cmp == .orderedAscending
            }
        case .year:
            result = library.albums.sorted {
                let y0 = $0.year ?? "9999"
                let y1 = $1.year ?? "9999"
                return y0 == y1 ? Self.titleOrder($0.title, $1.title) : y0 < y1
            }
        case .recentlyAdded:
            let added = albumDateAddedMap()
            result = library.albums.sorted {
                (added["\($0.title)|\($0.artist)"] ?? .distantPast) > (added["\($1.title)|\($1.artist)"] ?? .distantPast)
            }
        case .recentlyPlayed:
            let played = albumLastPlayedMap()
            let hasPlay = library.albums.filter { played["\($0.title)|\($0.artist)"] != nil }
                .sorted { (played["\($0.title)|\($0.artist)"] ?? .distantPast) > (played["\($1.title)|\($1.artist)"] ?? .distantPast) }
            let noPlay = library.albums.filter { played["\($0.title)|\($0.artist)"] == nil }
                .sorted { Self.titleOrder($0.title, $1.title) }
            result = hasPlay + noPlay
        }
        cacheLock.lock()
        cachedSortedAlbums = result
        cacheLock.unlock()
        return result
    }

    var sortedSongs: [Track] {
        cacheLock.lock()
        if let cached = cachedSortedSongs {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let tracks = library.allTracks
        guard !tracks.isEmpty else { return tracks }
        let result: [Track]
        switch songSort {
        case .title:
            result = tracks.sorted { Self.titleOrder($0.title, $1.title) }
        case .artist:
            result = tracks.sorted {
                let cmp = $0.artist.caseInsensitiveCompare($1.artist)
                return cmp == .orderedSame ? Self.titleOrder($0.title, $1.title) : cmp == .orderedAscending
            }
        case .mostScrobbled:
            guard let counts = cachedScrobbleCounts.flatMap({ $0.period == scrobbleRange ? $0.counts : nil }) else {
                warmScrobbleCountsIfNeeded()
                return tracks.sorted { Self.titleOrder($0.title, $1.title) }
            }
            let scored = tracks.filter { counts[LastFMStatsService.trackKey($0.title, $0.artist)] ?? 0 > 0 }
                .sorted {
                    let a = counts[LastFMStatsService.trackKey($0.title, $0.artist)] ?? 0
                    let b = counts[LastFMStatsService.trackKey($1.title, $1.artist)] ?? 0
                    return a == b ? Self.titleOrder($0.title, $1.title) : a > b
                }
            let unscrobbled = tracks.filter { counts[LastFMStatsService.trackKey($0.title, $0.artist)] ?? 0 == 0 }
                .sorted { Self.titleOrder($0.title, $1.title) }
            result = scored + unscrobbled
        case .recentlyPlayed:
            let sortKeys: [(fileURL: String, lastPlayed: Date?)]
            do {
                sortKeys = try DatabaseManager.shared.fetchTrackSortKeys()
            } catch {
                result = tracks.sorted { Self.titleOrder($0.title, $1.title) }
                cacheLock.lock()
                cachedSortedSongs = result
                cacheLock.unlock()
                return result
            }
            var lastPlayedByPath = [String: Date]()
            lastPlayedByPath.reserveCapacity(sortKeys.count)
            for key in sortKeys {
                if let date = key.lastPlayed {
                    lastPlayedByPath[key.fileURL] = date
                }
            }
            var pathByTrack = [URL: String]()
            pathByTrack.reserveCapacity(tracks.count)
            for track in tracks {
                pathByTrack[track.fileURL] = relativePath(for: track.fileURL)
            }
            let played = tracks.filter { lastPlayedByPath[pathByTrack[$0.fileURL] ?? ""] != nil }
                .sorted {
                    (lastPlayedByPath[pathByTrack[$0.fileURL] ?? ""] ?? .distantPast)
                        > (lastPlayedByPath[pathByTrack[$1.fileURL] ?? ""] ?? .distantPast)
                }
            let unplayed = tracks.filter { lastPlayedByPath[pathByTrack[$0.fileURL] ?? ""] == nil }
                .sorted { Self.titleOrder($0.title, $1.title) }
            result = played + unplayed
        case .dateAdded:
            let metaMap = trackMeta
            var pathByTrack = [URL: String]()
            pathByTrack.reserveCapacity(tracks.count)
            for track in tracks {
                pathByTrack[track.fileURL] = relativePath(for: track.fileURL)
            }
            result = tracks.sorted {
                let a = metaMap[pathByTrack[$0.fileURL] ?? ""]?.dateAdded ?? .distantPast
                let b = metaMap[pathByTrack[$1.fileURL] ?? ""]?.dateAdded ?? .distantPast
                return a > b
            }
        }
        cacheLock.lock()
        cachedSortedSongs = result
        cacheLock.unlock()
        return result
    }

    var sortedArtists: [ArtistItem] {
        cacheLock.lock()
        if let cached = cachedSortedArtists {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let result: [ArtistItem]
        switch artistSort {
        case .name:
            result = artists
        case .albumCount:
            result = artists.sorted {
                $0.albumCount == $1.albumCount
                    ? Self.titleOrder($0.name, $1.name)
                    : $0.albumCount > $1.albumCount
            }
        case .mostPlayed:
            let plays = artistPlayCounts()
            result = artists.sorted {
                let c0 = plays[artistMatchKey($0.name)] ?? 0
                let c1 = plays[artistMatchKey($1.name)] ?? 0
                return c0 == c1
                    ? Self.titleOrder($0.name, $1.name)
                    : c0 > c1
            }
        case .recentlyPlayed:
            let played = artistLastPlayedMap()
            let hasPlay = artists.filter { played[artistMatchKey($0.name)] != nil }
                .sorted { (played[artistMatchKey($0.name)] ?? .distantPast) > (played[artistMatchKey($1.name)] ?? .distantPast) }
            let noPlay = artists.filter { played[artistMatchKey($0.name)] == nil }
                .sorted { Self.titleOrder($0.name, $1.name) }
            result = hasPlay + noPlay
        }
        cacheLock.lock()
        cachedSortedArtists = result
        cacheLock.unlock()
        return result
    }

    /// Total Last.fm scrobbles per artist for the current scrobble range,
    /// keyed by lowercased artist name.
    func artistPlayCounts() -> [String: Int] {
        var map = [String: Int]()
        for entry in LastFMStatsService.shared.topArtists(period: scrobbleRange, limit: 1000) {
            map[artistMatchKey(entry.name), default: 0] += entry.playCount
        }
        return map
    }

    func artistLastPlayedMap() -> [String: Date] {
        var map = [String: Date]()
        for meta in trackMeta.values {
            guard let lastPlayed = meta.lastPlayed else { continue }
            let key = artistMatchKey(meta.track.artist)
            if let existing = map[key] {
                if lastPlayed > existing { map[key] = lastPlayed }
            } else {
                map[key] = lastPlayed
            }
        }
        return map
    }

    var recentlyPlayedAlbums: [Album] {
        if let cached = cachedRecentAlbums { return cached }
        let result: [Album]
        do {
            let recent = try DatabaseManager.shared.fetchRecentlyPlayedAlbums(limit: 6)
            result = recent.compactMap { pair in
                library.albums.first { $0.title == pair.albumTitle && $0.artist == pair.artist }
            }
        } catch { result = [] }
        cachedRecentAlbums = result
        return result
    }

    var playlists: [PlaylistItem] {
        if let cached = cachedPlaylists { return cached }
        let result: [PlaylistItem]
        do {
            let records = try DatabaseManager.shared.fetchAllPlaylists()
            let counts = (try? DatabaseManager.shared.fetchPlaylistTrackCounts()) ?? [:]
            result = records.compactMap { record in
                guard let id = record.id else { return nil }
                return PlaylistItem(id: id, name: record.name, trackCount: counts[id] ?? 0)
            }
        } catch {
            MidgarLog.error("Failed to fetch playlists: \(error.localizedDescription)", category: .database)
            result = []
        }
        cachedPlaylists = result
        return result
    }

    /// The Artists-tab grouping key for a possibly-collaborative credit. On the
    /// desktop this folds "Artist feat. X" / "Artist;X" under the lead artist;
    /// iOS keeps the raw credit unchanged.
    nonisolated func artistGroupKey(_ credit: String) -> String {
        #if os(macOS)
        return LibraryHygiene.primaryArtist(credit)
        #else
        return credit
        #endif
    }

    /// The normalized key two credits must share to be the same artist. On the
    /// desktop this folds collaborators, casing, diacritics and punctuation
    /// together; iOS keeps the raw credit.
    nonisolated func artistMatchKey(_ credit: String) -> String {
        #if os(macOS)
        return LibraryHygiene.artistKey(credit)
        #else
        return credit
        #endif
    }

    /// The Artists tab, built from what people are credited with **and** what
    /// they perform.
    ///
    /// Deriving it from album credits alone was fine while every album was one
    /// artist's, and became a disappearing act the moment compilations could
    /// exist: the seven composers of a Various Artists soundtrack own no album,
    /// so an index of credits alone would erase all seven from the library that
    /// holds thirty-one of their tracks. Performances therefore count too,
    /// tracked separately so the tab can still say which albums are actually
    /// theirs. Mirrors `build_artists` in the Linux client.
    var artists: [ArtistItem] {
        var seen = [String: ArtistItem]()

        func touch(_ credit: String, artwork: PlatformImage?, credited: Bool) {
            let key = artistMatchKey(credit)
            guard var existing = seen[key] else {
                seen[key] = ArtistItem(
                    name: artistGroupKey(credit),
                    albumCount: credited ? 1 : 0,
                    appearanceCount: credited ? 0 : 1,
                    artwork: artwork
                )
                return
            }
            existing = ArtistItem(
                name: existing.name,
                albumCount: existing.albumCount + (credited ? 1 : 0),
                appearanceCount: existing.appearanceCount + (credited ? 0 : 1),
                artwork: existing.artwork ?? artwork
            )
            seen[key] = existing
        }

        for album in library.albums {
            let creditKey = artistMatchKey(album.artist)
            touch(album.artist, artwork: album.artwork, credited: true)
            var performers: [String: String] = [:]
            for track in album.tracks {
                let key = artistMatchKey(track.artist)
                guard key != creditKey else { continue }
                performers[key] = track.artist
            }
            for credit in performers.values {
                touch(credit, artwork: album.artwork, credited: false)
            }
        }
        return seen.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
