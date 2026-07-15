import Foundation

/// Builds radio-style track queues from the local library: seeded by an artist
/// or track (biased toward Last.fm-similar artists already in the library) or by
/// the user's most-played tracks. Pure and off-main; callers snapshot the
/// library pool on the main thread and hand it in.
nonisolated enum StationBuilder {

    static let stationSize = 60
    static let continuationBatchSize = 30

    /// Weighted random ordering (Efraimidis–Spirakis): each element gets the key
    /// `u^(1/weight)` for a uniform `u`, sorted descending, so higher weights tend
    /// to sort earlier while every element keeps a chance — variety without bias loss.
    static func weightedShuffle<Element>(_ items: [Element], weight: (Element) -> Double) -> [Element] {
        items
            .map { element -> (element: Element, key: Double) in
                let w = max(weight(element), 0.0001)
                let u = Double.random(in: 1e-12..<1)
                return (element, pow(u, 1.0 / w))
            }
            .sorted { $0.key > $1.key }
            .map(\.element)
    }

    /// Reorders tracks so the same artist rarely plays back-to-back, preserving the
    /// incoming (already weighted) order within each artist.
    static func spacedByArtist(_ tracks: [Track]) -> [Track] {
        var buckets: [String: [Track]] = [:]
        var order: [String] = []
        for track in tracks {
            let key = track.artist.lowercased()
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(track)
        }

        var result: [Track] = []
        result.reserveCapacity(tracks.count)
        var lastArtist: String?
        while result.count < tracks.count {
            let remainingArtists = order.reduce(0) { $0 + ((buckets[$1]?.isEmpty ?? true) ? 0 : 1) }
            var placed = false
            for key in order {
                guard !(buckets[key]?.isEmpty ?? true) else { continue }
                if key == lastArtist, remainingArtists > 1 { continue }
                result.append(buckets[key]!.removeFirst())
                lastArtist = key
                placed = true
                break
            }
            if !placed {
                for key in order where !(buckets[key]?.isEmpty ?? true) {
                    result.append(buckets[key]!.removeFirst())
                    lastArtist = key
                    break
                }
            }
        }
        return result
    }

    /// Seed-artist station: the seed's own tracks (weight 1) plus tracks by
    /// similar-in-library artists, each weighted by the Last.fm match score.
    static func artistStation(
        seedArtist: String,
        pool: [Track],
        excluding: Set<URL>,
        limit: Int
    ) async -> [Track] {
        let matches = await SimilarArtistService.shared.similarArtistsInLibrary(toArtist: seedArtist)
        var weights: [String: Double] = [seedArtist.lowercased(): 1.0]
        for match in matches {
            weights[match.name.lowercased()] = max(0.1, min(0.95, match.match))
        }

        let candidates = pool.filter { track in
            !excluding.contains(track.fileURL) && weights[track.artist.lowercased()] != nil
        }
        guard !candidates.isEmpty else { return [] }

        let shuffled = weightedShuffle(candidates) { weights[$0.artist.lowercased()] ?? 0.1 }
        return Array(spacedByArtist(Array(shuffled.prefix(limit * 2))).prefix(limit))
    }

    /// Seed-track station: an artist station for the track's artist with the seed
    /// track guaranteed first. Falls back to a pure artist station when the seed is
    /// excluded (e.g. already queued).
    static func trackStation(
        seedTrack: Track,
        pool: [Track],
        excluding: Set<URL>,
        limit: Int
    ) async -> [Track] {
        var station = await artistStation(
            seedArtist: seedTrack.artist,
            pool: pool,
            excluding: excluding,
            limit: limit
        )
        if !excluding.contains(seedTrack.fileURL) {
            station.removeAll { $0.fileURL == seedTrack.fileURL }
            station.insert(seedTrack, at: 0)
        }
        return station
    }

    /// Most-played station: every library track weighted by its scrobble count so
    /// favourites dominate while unplayed tracks still surface for variety.
    static func libraryRadio(
        pool: [Track],
        playCounts: [(trackTitle: String, artist: String, count: Int)],
        excluding: Set<URL>,
        limit: Int
    ) -> [Track] {
        var countByKey: [String: Int] = [:]
        for entry in playCounts { countByKey[trackKey(entry.trackTitle, entry.artist)] = entry.count }

        let candidates = pool.filter { !excluding.contains($0.fileURL) }
        guard !candidates.isEmpty else { return [] }

        let weighted = weightedShuffle(candidates) { track in
            1.0 + Double(countByKey[trackKey(track.title, track.artist)] ?? 0)
        }
        return Array(spacedByArtist(Array(weighted.prefix(limit * 2))).prefix(limit))
    }

    /// Crate Dig: underplayed tracks from albums the listener already knows.
    /// An album qualifies when it has enough tracks and enough history that at
    /// least one song has been played; candidates are tracks that sit well below
    /// that album's peak play count — the sides you own but never queue.
    static func crateDig(
        pool: [Track],
        playCounts: [(trackTitle: String, artist: String, count: Int)],
        excluding: Set<URL>,
        limit: Int
    ) -> [Track] {
        var countByKey: [String: Int] = [:]
        for entry in playCounts { countByKey[trackKey(entry.trackTitle, entry.artist)] = entry.count }

        var albums: [String: [Track]] = [:]
        for track in pool where !excluding.contains(track.fileURL) {
            let key = albumKey(track.albumTitle, track.artist)
            albums[key, default: []].append(track)
        }

        var scored: [(track: Track, weight: Double)] = []
        for tracks in albums.values {
            guard tracks.count >= 4 else { continue }
            let counts = tracks.map { countByKey[trackKey($0.title, $0.artist)] ?? max(0, $0.playCount) }
            let albumPlays = counts.reduce(0, +)
            let peak = counts.max() ?? 0
            guard albumPlays >= 3, peak >= 2 else { continue }
            let threshold = max(0, peak / 3)
            for (track, count) in zip(tracks, counts) where count <= threshold {
                let weight = Double(albumPlays) / Double(count + 1) * (1.0 + Double(peak - count))
                scored.append((track, max(weight, 0.1)))
            }
        }
        guard !scored.isEmpty else { return [] }

        let weighted = weightedShuffle(scored.map(\.track)) { track in
            scored.first(where: { $0.track.fileURL == track.fileURL })?.weight ?? 0.1
        }
        return Array(spacedByArtist(Array(weighted.prefix(limit * 2))).prefix(limit))
    }

    private static func trackKey(_ title: String, _ artist: String) -> String {
        "\(title.lowercased())\u{0}\(artist.lowercased())"
    }

    private static func albumKey(_ album: String, _ artist: String) -> String {
        "\(album.lowercased())\u{0}\(artist.lowercased())"
    }
}
