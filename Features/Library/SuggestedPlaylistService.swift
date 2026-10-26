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
/// the caller snapshots `Library.shared.allTracks` and hands it in. Each
/// song's listen key is folded once per build, `keys[i]` being `pool[i]`'s,
/// and each play's is read as stored: Home rebuilds the mixes on every change
/// it shows, so this has to stay cheap on a library of thousands.
nonisolated enum SuggestedPlaylistService {

    private static let maxTracks = 50
    private static let minTracks = 8

    static func build(pool: [Track]) -> [SuggestedPlaylist] {
        guard !pool.isEmpty else { return [] }

        let keys = pool.map { key($0.title, $0.artist) }
        var poolByKey: [String: Track] = [:]
        poolByKey.reserveCapacity(pool.count)
        for (track, k) in zip(pool, keys) where poolByKey[k] == nil {
            poolByKey[k] = track
        }

        let rows = (try? DatabaseManager.shared.fetchListens()) ?? []
        guard !rows.isEmpty else { return [] }

        let now = Date()
        let recentCutoff = now.addingTimeInterval(-90 * 86400)
        let monthCutoff = now.addingTimeInterval(-30 * 86400)

        var allCounts: [String: Int] = [:]
        var recentCounts: [String: Int] = [:]
        var monthCounts: [String: Int] = [:]
        var artistCounts: [String: Int] = [:]
        for row in rows {
            let k = row.key
            allCounts[k, default: 0] += 1
            artistCounts[row.artist.lowercased(), default: 0] += 1
            if row.timestamp >= recentCutoff { recentCounts[k, default: 0] += 1 }
            if row.timestamp >= monthCutoff { monthCounts[k, default: 0] += 1 }
        }

        var suggestions: [SuggestedPlaylist] = []
        if let heavy = heavyRotation(poolByKey: poolByKey, monthCounts: monthCounts, allCounts: allCounts) {
            suggestions.append(heavy)
        }
        if let dig = crateDig(pool: pool, keys: keys, allCounts: allCounts) {
            suggestions.append(dig)
        }
        if let repeatArtist = onRepeat(pool: pool, keys: keys, artistCounts: artistCounts, allCounts: allCounts) {
            suggestions.append(repeatArtist)
        }
        if let rediscover = rediscover(poolByKey: poolByKey, allCounts: allCounts, recentCounts: recentCounts) {
            suggestions.append(rediscover)
        }
        if let spin = tonightsSpin(pool: pool, keys: keys, allCounts: allCounts, recentCounts: recentCounts) {
            suggestions.append(spin)
        }
        return suggestions
    }

    /// Underplayed tracks from albums you already love — the crate-digging
    /// privilege of owning full albums instead of streaming singles.
    private static func crateDig(pool: [Track], keys: [String], allCounts: [String: Int]) -> SuggestedPlaylist? {
        var pairs: [(key: String, count: Int)] = []
        var seen = Set<String>()
        for (track, k) in zip(pool, keys) {
            guard seen.insert(k).inserted else { continue }
            pairs.append((k, allCounts[k] ?? track.playCount))
        }
        let tracks = StationBuilder.crateDig(
            pool: pool, keys: keys, playCounts: pairs, excluding: [], limit: maxTracks
        )
        guard tracks.count >= minTracks else { return nil }
        return SuggestedPlaylist(
            id: "crate-dig", title: String(localized: "Crate Dig"),
            subtitle: String(localized: "Deep cuts from albums you already love"),
            systemImage: "opticaldisc.fill", tracks: tracks
        )
    }

    /// One full album you own but haven't spun recently — album-night mode.
    /// Picks with a day-stable seed so the suggestion holds for the evening
    /// instead of reshuffling on every library refresh.
    private static func tonightsSpin(
        pool: [Track], keys: [String], allCounts: [String: Int], recentCounts: [String: Int]
    ) -> SuggestedPlaylist? {
        var albums: [String: [Int]] = [:]
        for (index, track) in pool.enumerated() {
            let k = "\(track.albumTitle.lowercased())\u{0}\(track.artist.lowercased())"
            albums[k, default: []].append(index)
        }

        var candidates: [(tracks: [Track], weight: Double, title: String, artist: String)] = []
        for members in albums.values {
            guard members.count >= 5 else { continue }
            let recentPlays = members.reduce(0) { $0 + (recentCounts[keys[$1]] ?? 0) }
            guard recentPlays == 0 else { continue }
            let albumPlays = members.reduce(0) { $0 + (allCounts[keys[$1]] ?? 0) }
            let ordered = members.map { pool[$0] }.sorted {
                if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
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
            ? String(localized: "Full album night")
            : String(localized: "Full album · \(pick.artist)")
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
            ? String(localized: "Your most-played this month")
            : String(localized: "The songs you keep coming back to")
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
            id: "heavy-rotation", title: String(localized: "Heavy Rotation"),
            subtitle: subtitle, systemImage: "flame.fill", tracks: tracks
        )
    }

    private static func onRepeat(
        pool: [Track], keys: [String], artistCounts: [String: Int], allCounts: [String: Int]
    ) -> SuggestedPlaylist? {
        let ranked = artistCounts.sorted { $0.value > $1.value }
        let leaders = Set(ranked.prefix(8).map(\.key))
        var ownedByArtist: [String: [(track: Track, plays: Int)]] = [:]
        for (track, k) in zip(pool, keys) {
            let artistLower = track.artist.lowercased()
            guard leaders.contains(artistLower) else { continue }
            ownedByArtist[artistLower, default: []].append((track, allCounts[k] ?? 0))
        }
        for (artistLower, _) in ranked.prefix(8) {
            let owned = ownedByArtist[artistLower] ?? []
            guard owned.count >= minTracks else { continue }
            let ordered = owned.sorted { $0.plays > $1.plays }.map(\.track)
            let tracks = Array(ordered.prefix(maxTracks))
            let displayArtist = tracks.first?.artist ?? artistLower
            return SuggestedPlaylist(
                id: "on-repeat", title: String(localized: "On Repeat"),
                subtitle: String(localized: "The best of \(displayArtist)"), systemImage: "repeat",
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
            id: "rediscover", title: String(localized: "Rediscover"),
            subtitle: String(localized: "Favourites you haven't heard in months"),
            systemImage: "clock.arrow.circlepath", tracks: tracks
        )
    }

    private static func key(_ title: String, _ artist: String) -> String {
        SpellingMemo.listenKeys.key(title: title, artist: artist)
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
