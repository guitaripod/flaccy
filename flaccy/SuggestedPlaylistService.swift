import Foundation

nonisolated struct SuggestedPlaylist: Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let tracks: [Track]

    nonisolated static func == (lhs: SuggestedPlaylist, rhs: SuggestedPlaylist) -> Bool {
        lhs.id == rhs.id && lhs.tracks.count == rhs.tracks.count
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(tracks.count)
    }
}

/// Derives a handful of ready-to-play playlists by intersecting the user's
/// Last.fm scrobble history with the tracks they actually own locally. Pure and
/// off-main; the caller snapshots `Library.shared.allTracks` and hands it in.
nonisolated enum SuggestedPlaylistService {

    private static let maxTracks = 50
    private static let minTracks = 8

    static func build(pool: [Track]) -> [SuggestedPlaylist] {
        guard LastFMService.shared.isAuthenticated, !pool.isEmpty else { return [] }

        var poolByKey: [String: Track] = [:]
        poolByKey.reserveCapacity(pool.count)
        for track in pool where poolByKey[key(track.title, track.artist)] == nil {
            poolByKey[key(track.title, track.artist)] = track
        }

        let rows = (try? DatabaseManager.shared.fetchAllScrobbleRows()) ?? []
        guard !rows.isEmpty else { return [] }

        let now = Date()
        let recentCutoff = now.addingTimeInterval(-90 * 86400)
        let monthCutoff = now.addingTimeInterval(-30 * 86400)

        var allCounts: [String: Int] = [:]
        var recentCounts: [String: Int] = [:]
        var monthCounts: [String: Int] = [:]
        var artistCounts: [String: Int] = [:]
        for row in rows {
            let k = key(row.trackTitle, row.artist)
            allCounts[k, default: 0] += 1
            artistCounts[row.artist.lowercased(), default: 0] += 1
            if row.timestamp >= recentCutoff { recentCounts[k, default: 0] += 1 }
            if row.timestamp >= monthCutoff { monthCounts[k, default: 0] += 1 }
        }

        var suggestions: [SuggestedPlaylist] = []
        if let heavy = heavyRotation(poolByKey: poolByKey, monthCounts: monthCounts, allCounts: allCounts) {
            suggestions.append(heavy)
        }
        if let repeatArtist = onRepeat(pool: pool, artistCounts: artistCounts, allCounts: allCounts) {
            suggestions.append(repeatArtist)
        }
        if let rediscover = rediscover(poolByKey: poolByKey, allCounts: allCounts, recentCounts: recentCounts) {
            suggestions.append(rediscover)
        }
        return suggestions
    }

    private static func heavyRotation(
        poolByKey: [String: Track], monthCounts: [String: Int], allCounts: [String: Int]
    ) -> SuggestedPlaylist? {
        let useMonth = monthCounts.values.reduce(0, +) >= minTracks
        let counts = useMonth ? monthCounts : allCounts
        let subtitle = useMonth
            ? "Your most-played this month"
            : "The songs you keep coming back to"
        let ordered = counts
            .compactMap { entry -> (track: Track, count: Int)? in
                guard let track = poolByKey[entry.key] else { return nil }
                return (track, entry.value)
            }
            .sorted { $0.count > $1.count }
            .map(\.track)
        let tracks = Array(StationBuilder.spacedByArtist(Array(ordered.prefix(maxTracks * 2))).prefix(maxTracks))
        guard tracks.count >= minTracks else { return nil }
        return SuggestedPlaylist(
            id: "heavy-rotation", title: "Heavy Rotation",
            subtitle: subtitle, systemImage: "flame.fill", tracks: tracks
        )
    }

    private static func onRepeat(
        pool: [Track], artistCounts: [String: Int], allCounts: [String: Int]
    ) -> SuggestedPlaylist? {
        let ranked = artistCounts.sorted { $0.value > $1.value }
        for (artistLower, _) in ranked.prefix(8) {
            let owned = pool.filter { $0.artist.lowercased() == artistLower }
            guard owned.count >= minTracks else { continue }
            let ordered = owned.sorted {
                (allCounts[key($0.title, $0.artist)] ?? 0) > (allCounts[key($1.title, $1.artist)] ?? 0)
            }
            let tracks = Array(ordered.prefix(maxTracks))
            let displayArtist = tracks.first?.artist ?? artistLower
            return SuggestedPlaylist(
                id: "on-repeat", title: "On Repeat",
                subtitle: "The best of \(displayArtist)", systemImage: "repeat",
                tracks: tracks
            )
        }
        return nil
    }

    private static func rediscover(
        poolByKey: [String: Track], allCounts: [String: Int], recentCounts: [String: Int]
    ) -> SuggestedPlaylist? {
        let ordered = allCounts
            .filter { $0.value >= 3 && (recentCounts[$0.key] ?? 0) == 0 }
            .compactMap { entry -> (track: Track, count: Int)? in
                guard let track = poolByKey[entry.key] else { return nil }
                return (track, entry.value)
            }
            .sorted { $0.count > $1.count }
            .map(\.track)
        let tracks = Array(StationBuilder.spacedByArtist(Array(ordered.prefix(maxTracks * 2))).prefix(maxTracks))
        guard tracks.count >= minTracks else { return nil }
        return SuggestedPlaylist(
            id: "rediscover", title: "Rediscover",
            subtitle: "Favourites you haven't heard in months",
            systemImage: "clock.arrow.circlepath", tracks: tracks
        )
    }

    private static func key(_ title: String, _ artist: String) -> String {
        LastFMStatsService.trackKey(title, artist)
    }
}
