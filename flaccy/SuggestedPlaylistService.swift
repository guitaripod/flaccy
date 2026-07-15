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
/// local play history with the tracks they actually own. Pure and off-main;
/// the caller snapshots `Library.shared.allTracks` and hands it in.
nonisolated enum SuggestedPlaylistService {

    private static let maxTracks = 50
    private static let minTracks = 8

    static func build(pool: [Track]) -> [SuggestedPlaylist] {
        guard !pool.isEmpty else { return [] }

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
        if let dig = crateDig(pool: pool, allCounts: allCounts) {
            suggestions.append(dig)
        }
        if let repeatArtist = onRepeat(pool: pool, artistCounts: artistCounts, allCounts: allCounts) {
            suggestions.append(repeatArtist)
        }
        if let rediscover = rediscover(poolByKey: poolByKey, allCounts: allCounts, recentCounts: recentCounts) {
            suggestions.append(rediscover)
        }
        if let spin = tonightsSpin(pool: pool, allCounts: allCounts, recentCounts: recentCounts) {
            suggestions.append(spin)
        }
        return suggestions
    }

    /// Underplayed tracks from albums you already love — the crate-digging
    /// privilege of owning full albums instead of streaming singles.
    private static func crateDig(pool: [Track], allCounts: [String: Int]) -> SuggestedPlaylist? {
        var pairs: [(trackTitle: String, artist: String, count: Int)] = []
        var seen = Set<String>()
        for track in pool {
            let k = key(track.title, track.artist)
            guard seen.insert(k).inserted else { continue }
            pairs.append((track.title, track.artist, allCounts[k] ?? track.playCount))
        }
        let tracks = StationBuilder.crateDig(
            pool: pool, playCounts: pairs, excluding: [], limit: maxTracks
        )
        guard tracks.count >= minTracks else { return nil }
        return SuggestedPlaylist(
            id: "crate-dig", title: "Crate Dig",
            subtitle: "Deep cuts from albums you already love",
            systemImage: "opticaldisc.fill", tracks: tracks
        )
    }

    /// One full album you own but haven't spun recently — album-night mode.
    /// Picks with a day-stable seed so the suggestion holds for the evening
    /// instead of reshuffling on every library refresh.
    private static func tonightsSpin(
        pool: [Track], allCounts: [String: Int], recentCounts: [String: Int]
    ) -> SuggestedPlaylist? {
        var albums: [String: [Track]] = [:]
        for track in pool {
            let k = "\(track.albumTitle.lowercased())\u{0}\(track.artist.lowercased())"
            albums[k, default: []].append(track)
        }

        var candidates: [(tracks: [Track], weight: Double, title: String, artist: String)] = []
        for group in albums.values {
            guard group.count >= 5 else { continue }
            let ordered = group.sorted {
                if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            let albumPlays = ordered.reduce(0) { $0 + (allCounts[key($1.title, $1.artist)] ?? 0) }
            let recentPlays = ordered.reduce(0) { $0 + (recentCounts[key($1.title, $1.artist)] ?? 0) }
            guard recentPlays == 0 else { continue }
            let historyBoost = albumPlays > 0 ? log2(1.0 + Double(albumPlays)) : 0.35
            let weight = historyBoost * Double(ordered.count)
            candidates.append((ordered, weight, ordered[0].albumTitle, ordered[0].artist))
        }
        guard !candidates.isEmpty else { return nil }

        let daySeed = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let ranked = StationBuilder.weightedShuffle(candidates) { candidate in
            let mix = stableMix(daySeed, candidate.title, candidate.artist)
            return candidate.weight * (0.5 + mix)
        }
        guard let pick = ranked.first else { return nil }
        let subtitle = pick.artist.isEmpty
            ? "Full album night"
            : "Full album · \(pick.artist)"
        return SuggestedPlaylist(
            id: "tonights-spin", title: pick.title,
            subtitle: subtitle, systemImage: "record.circle", tracks: pick.tracks
        )
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

    /// Deterministic 0…1 mix for day-stable Tonight's Spin ranking (Swift's
    /// Hasher is process-randomized and can't be used for this).
    private static func stableMix(_ daySeed: Int, _ title: String, _ artist: String) -> Double {
        var hash: UInt64 = 5381 &+ UInt64(daySeed)
        for byte in "\(title.lowercased())\u{0}\(artist.lowercased())".utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return Double(hash % 10_000) / 10_000.0
    }
}
