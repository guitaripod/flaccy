import Combine
import MidgarCore
import FlaccyCore

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension LibraryViewModel {

    /// The album signals every chip reads, built once and held until the
    /// library, the play history or the day changes.
    ///
    /// Everything here is in memory: `trackMeta` is warmed off the main actor
    /// before a snapshot is built, and the values are the database's own track
    /// columns, which the history import and every scrobble reconcile. A chip
    /// click therefore reads dictionaries instead of asking SQLite for an album
    /// aggregate and asking the disk about every file in the library.
    func filterSignals() -> FilterSignals {
        let stamp = (day: Calendar.current.startOfDay(for: Date()), revision: LastFMStatsService.shared.scrobbleRevision)
        if let cached = cachedFilterSignals, cachedFilterSignalsStamp?.day == stamp.day,
           cachedFilterSignalsStamp?.revision == stamp.revision {
            return cached
        }
        let built = Self.buildFilterSignals(albums: library.albums, meta: trackMeta, now: stamp.day)
        cachedFilterSignals = built
        cachedFilterSignalsStamp = stamp
        return built
    }

    /// One pass over the library's albums and the warmed metadata, producing the
    /// maps the chips need and the Rediscover order from the shared rules.
    nonisolated static func buildFilterSignals(
        albums: [Album],
        meta: [String: TrackMeta],
        now: Date
    ) -> FilterSignals {
        var added = [String: Date](minimumCapacity: albums.count)
        var played = [String: Date](minimumCapacity: albums.count)
        var entries: [(id: String, plays: Int, lastPlayed: Date?)] = []
        entries.reserveCapacity(albums.count)

        for album in albums {
            let key = albumFilterKey(album)
            var newest = Date.distantPast
            var lastPlayed: Date?
            var total = 0
            for track in album.tracks {
                guard let trackMeta = meta[LibraryPaths.relativePath(of: track.fileURL)] else { continue }
                if trackMeta.dateAdded > newest { newest = trackMeta.dateAdded }
                if let heardAt = trackMeta.lastPlayed, heardAt > (lastPlayed ?? .distantPast) { lastPlayed = heardAt }
                total += trackMeta.track.playCount
            }
            added[key] = newest
            if let lastPlayed { played[key] = lastPlayed }
            entries.append((id: key, plays: total, lastPlayed: lastPlayed))
        }

        let order = LibraryFilterRules.rediscover(entries, now: now)
        var byKey = [String: Album](minimumCapacity: albums.count)
        for album in albums where byKey[albumFilterKey(album)] == nil {
            byKey[albumFilterKey(album)] = album
        }
        return FilterSignals(
            added: added,
            played: played,
            rediscover: (keys: Set(order), albums: order.compactMap { byKey[$0] })
        )
    }

    /// The identity a chip ranks an album by, identical to the Linux client's
    /// `Album::key`.
    nonisolated static func albumFilterKey(_ album: Album) -> String {
        "\(album.title)|\(album.artist)"
    }

    /// The albums among `albums` ordered by `ids`, dropping any the library no
    /// longer holds.
    func albums(_ albums: [Album], for ids: [String]) -> [Album] {
        var byKey = [String: Album](minimumCapacity: albums.count)
        for album in albums where byKey[Self.albumFilterKey(album)] == nil {
            byKey[Self.albumFilterKey(album)] = album
        }
        return ids.compactMap { byKey[$0] }
    }

    /// The songs among `songs` ordered by `ids`, dropping any that are no longer
    /// there.
    func songs(_ songs: [Track], for ids: [String]) -> [Track] {
        var byPath = [String: Track](minimumCapacity: songs.count)
        for song in songs {
            let path = LibraryPaths.relativePath(of: song.fileURL)
            if byPath[path] == nil { byPath[path] = song }
        }
        return ids.compactMap { byPath[$0] }
    }

    /// The rows the Recently Added and Recently Played chips rank, keyed by the
    /// identity the shared rules hand back.
    func addedEntries(_ tracks: [Track]) -> [(id: String, dateAdded: Date)] {
        let meta = trackMeta
        return tracks.map { track in
            let path = LibraryPaths.relativePath(of: track.fileURL)
            return (id: path, dateAdded: meta[path]?.dateAdded ?? .distantPast)
        }
    }

    func playedEntries(_ tracks: [Track]) -> [(id: String, lastPlayed: Date?)] {
        let meta = trackMeta
        return tracks.map { track in
            let path = LibraryPaths.relativePath(of: track.fileURL)
            return (id: path, lastPlayed: meta[path]?.lastPlayed)
        }
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
        filterSignals().rediscover
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
            let added = filterSignals().added
            result = library.albums.sorted {
                (added[Self.albumFilterKey($0)] ?? .distantPast) > (added[Self.albumFilterKey($1)] ?? .distantPast)
            }
        case .recentlyPlayed:
            let played = filterSignals().played
            let hasPlay = library.albums.filter { played[Self.albumFilterKey($0)] != nil }
                .sorted { (played[Self.albumFilterKey($0)] ?? .distantPast) > (played[Self.albumFilterKey($1)] ?? .distantPast) }
            let noPlay = library.albums.filter { played[Self.albumFilterKey($0)] == nil }
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
            var scored: [(track: Track, plays: Int)] = []
            var unscrobbled: [Track] = []
            scored.reserveCapacity(tracks.count)
            for track in tracks {
                let plays = counts[LastFMStatsService.trackKey(track.title, track.artist)] ?? 0
                if plays > 0 {
                    scored.append((track, plays))
                } else {
                    unscrobbled.append(track)
                }
            }
            let ranked = scored.sorted { lhs, rhs in
                lhs.plays == rhs.plays ? Self.titleOrder(lhs.track.title, rhs.track.title) : lhs.plays > rhs.plays
            }.map(\.track)
            result = ranked + unscrobbled.sorted { Self.titleOrder($0.title, $1.title) }
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
            var played: [(track: Track, date: Date)] = []
            var unplayed: [Track] = []
            played.reserveCapacity(tracks.count)
            for track in tracks {
                if let date = lastPlayedByPath[LibraryPaths.relativePath(of: track.fileURL)] {
                    played.append((track, date))
                } else {
                    unplayed.append(track)
                }
            }
            result = played.sorted { $0.date > $1.date }.map(\.track)
                + unplayed.sorted { Self.titleOrder($0.title, $1.title) }
        case .dateAdded:
            let metaMap = trackMeta
            var dated: [(track: Track, date: Date)] = []
            dated.reserveCapacity(tracks.count)
            for track in tracks {
                dated.append((track, metaMap[LibraryPaths.relativePath(of: track.fileURL)]?.dateAdded ?? .distantPast))
            }
            result = dated.sorted { $0.date > $1.date }.map(\.track)
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
