import Foundation
import FlaccyCore

nonisolated extension LibraryHygiene {

    static func duplicateKey(_ track: Track) -> String {
        [
            artistKey(track.artist),
            consolidationBaseTitle(track.albumTitle),
            String(track.trackNumber),
            normalize(track.title),
        ].joined(separator: "\u{0}")
    }

    static func qualityRank(_ track: Track) -> (Int, Int, Int, Int, Int) {
        let size = (try? track.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return (isLossless(track.codec) ? 1 : 0, track.bitDepth ?? 0, track.sampleRate ?? 0, track.channels ?? 0, size)
    }

    struct DuplicateGroup: Sendable {
        let keeper: Track
        let losers: [Track]
    }

    /// Groups tracks that share artist + edition-normalized album + track number
    /// + title, then splits each group into runs whose durations cluster within
    /// ±2 s so two genuinely different songs sharing a title/track number are not
    /// fused. Only runs of 2+ survive; the highest-quality copy is the keeper.
    static func duplicateGroups(_ tracks: [Track]) -> [DuplicateGroup] {
        var byKey: [String: [Track]] = [:]
        for track in tracks {
            byKey[duplicateKey(track), default: []].append(track)
        }
        var groups: [DuplicateGroup] = []
        for members in byKey.values where members.count >= 2 {
            let sorted = members.sorted { $0.duration < $1.duration }
            var cluster: [Track] = []
            var previous: TimeInterval?
            for track in sorted {
                if let previous, track.duration - previous > 2.0, cluster.count >= 2 {
                    groups.append(makeGroup(cluster))
                    cluster = []
                } else if let previous, track.duration - previous > 2.0 {
                    cluster = []
                }
                cluster.append(track)
                previous = track.duration
            }
            if cluster.count >= 2 {
                groups.append(makeGroup(cluster))
            }
        }
        return groups
    }

    private static func makeGroup(_ members: [Track]) -> DuplicateGroup {
        let ranked = members.sorted { lhs, rhs in
            let lRank = qualityRank(lhs), rRank = qualityRank(rhs)
            if lRank != rRank { return lRank > rRank }
            let lID = lhs.dbID ?? Int64.max, rID = rhs.dbID ?? Int64.max
            if lID != rID { return lID < rID }
            return lhs.fileURL.path < rhs.fileURL.path
        }
        return DuplicateGroup(keeper: ranked[0], losers: Array(ranked.dropFirst()))
    }

    // MARK: Duplicate songs across albums

    /// What marks a bracketed or dashed title suffix as the same recording
    /// re-released. Live, acoustic, demo, instrumental and remix are left out
    /// on purpose: those are different recordings of the song.
    static let songEditionKeywords: Set<String> = [
        "remaster", "remastered", "remasters", "mono", "stereo", "explicit", "clean",
        "deluxe", "edition", "bonus", "reissue", "reissued", "expanded", "anniversary",
        "feat", "featuring", "ft.",
    ]

    /// Copies of one song whose lengths differ by more than this are treated as
    /// different recordings even when title and artist agree.
    static let songDurationTolerance: TimeInterval = 3.0

    /// The identity of a song regardless of the release it sits on: the lead
    /// artist and the title with re-release decoration removed.
    static func songKey(title: String, artist: String) -> String {
        artistKey(artist) + "\u{0}" + baseTitle(title, keywords: songEditionKeywords)
    }

    struct DuplicateSongs: Sendable {
        let tracks: [Track]
        let copies: [URL: [Track]]
    }

    /// Keeps one copy of every song in `tracks` and reports the copies it hid.
    /// Same song means the same `songKey` with lengths that chain together
    /// within `songDurationTolerance`. The keeper is the copy `prefers` ranks
    /// highest (the one the person loved or plays), then the highest fidelity,
    /// then the oldest row. The original order is preserved.
    static func collapsingDuplicateSongs(
        _ tracks: [Track],
        prefers rank: (Track) -> Int = { _ in 0 }
    ) -> DuplicateSongs {
        var byKey: [String: [Track]] = [:]
        for track in tracks where !track.title.isEmpty {
            byKey[SpellingMemo.songKeys.key(title: track.title, artist: track.artist), default: []].append(track)
        }
        var hidden = Set<URL>()
        var copies: [URL: [Track]] = [:]
        for members in byKey.values where members.count >= 2 {
            let sorted = members.sorted { $0.duration < $1.duration }
            var cluster: [Track] = []
            func flush() {
                defer { cluster = [] }
                guard cluster.count >= 2 else { return }
                let ranked = cluster.sorted { lhs, rhs in
                    let lRank = rank(lhs), rRank = rank(rhs)
                    if lRank != rRank { return lRank > rRank }
                    let lQuality = trackQualityScalar(lhs), rQuality = trackQualityScalar(rhs)
                    if lQuality != rQuality { return lQuality > rQuality }
                    let lID = lhs.dbID ?? Int64.max, rID = rhs.dbID ?? Int64.max
                    if lID != rID { return lID < rID }
                    return lhs.fileURL.path < rhs.fileURL.path
                }
                copies[ranked[0].fileURL] = Array(ranked.dropFirst())
                for loser in ranked.dropFirst() { hidden.insert(loser.fileURL) }
            }
            var previous: TimeInterval?
            for track in sorted {
                if let previous, track.duration - previous > songDurationTolerance { flush() }
                cluster.append(track)
                previous = track.duration
            }
            flush()
        }
        guard !hidden.isEmpty else { return DuplicateSongs(tracks: tracks, copies: [:]) }
        return DuplicateSongs(tracks: tracks.filter { !hidden.contains($0.fileURL) }, copies: copies)
    }

    // MARK: Album-variation consolidation

    struct ConsolidationGroup: Sendable {
        let canonicalTitle: String
        let canonicalArtist: String
        let variants: [AlbumVariant]
        var albumCount: Int { variants.count + 1 }
    }

    /// Groups albums by artist + edition-normalized base title (exact equality,
    /// so "Greatest Hits Vol. 1" and "Vol. 2" stay separate) and picks the
    /// superset variant (most tracks, then shortest raw title, then most lossless
    /// tracks) as the canonical album the others fold into.
    static func consolidationGroups(_ albums: [Album]) -> [ConsolidationGroup] {
        var byKey: [String: [Album]] = [:]
        for album in albums {
            byKey[consolidationKey(title: album.title, artist: album.artist), default: []].append(album)
        }
        var groups: [ConsolidationGroup] = []
        for variants in byKey.values where Set(variants.map(\.title)).count >= 2 {
            guard let canonical = variants.max(by: { lhs, rhs in
                (lhs.tracks.count, -lhs.title.count, aggregateQuality(lhs))
                    < (rhs.tracks.count, -rhs.title.count, aggregateQuality(rhs))
            }) else { continue }
            var seen = Set<String>()
            let others = variants
                .filter { $0.title != canonical.title }
                .filter { seen.insert($0.title).inserted }
                .map { AlbumVariant(title: $0.title, artist: $0.artist) }
            groups.append(ConsolidationGroup(
                canonicalTitle: canonical.title,
                canonicalArtist: canonical.artist,
                variants: others
            ))
        }
        return groups
    }

    private static func aggregateQuality(_ album: Album) -> Int {
        album.tracks.reduce(0) { total, track in
            total + trackQualityScalar(track)
        }
    }

    static func trackQualityScalar(_ track: Track) -> Int {
        (isLossless(track.codec) ? 1_000_000_000 : 0)
            + (track.bitDepth ?? 0) * 1_000_000
            + (track.sampleRate ?? 0)
    }

    /// Fuses editions of the same release into one display album: the canonical
    /// title/artist, the union of every variant's tracks deduplicated by
    /// `duplicateKey` keeping the highest-fidelity copy, and the richest
    /// available metadata. Mirrors Linux `hygiene::consolidate_albums`.
    static func consolidateAlbums(_ albums: [Album]) -> [Album] {
        var order: [String] = []
        var byKey: [String: [Album]] = [:]
        for album in albums {
            let key = consolidationKey(title: album.title, artist: album.artist)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(album)
        }
        return order.compactMap { key in
            guard let group = byKey[key] else { return nil }
            if group.count == 1 { return group[0] }
            return mergeAlbumGroup(group)
        }
    }

    private static func mergeAlbumGroup(_ group: [Album]) -> Album {
        let canonical = group.max { lhs, rhs in
            (lhs.tracks.count, -lhs.title.count, aggregateQuality(lhs))
                < (rhs.tracks.count, -rhs.title.count, aggregateQuality(rhs))
        } ?? group[0]
        let title = canonical.title
        let artist = canonical.artist
        let year = canonical.year.flatMap { $0.isEmpty ? nil : $0 }
            ?? group.lazy.compactMap(\.year).first { !$0.isEmpty }
        let genre = canonical.genre.flatMap { $0.isEmpty ? nil : $0 }
            ?? group.lazy.compactMap(\.genre).first { !$0.isEmpty }

        var order: [String] = []
        var best: [String: Track] = [:]
        for album in group {
            for track in album.tracks {
                let key = duplicateKey(track)
                if let existing = best[key] {
                    if trackQualityScalar(track) > trackQualityScalar(existing) {
                        best[key] = track
                    } else if trackQualityScalar(track) == trackQualityScalar(existing) {
                        let lID = track.dbID ?? Int64.max
                        let rID = existing.dbID ?? Int64.max
                        if lID < rID || (lID == rID && track.fileURL.path < existing.fileURL.path) {
                            best[key] = track
                        }
                    }
                } else {
                    order.append(key)
                    best[key] = track
                }
            }
        }
        let merged = order.compactMap { key -> Track? in
            guard let track = best[key] else { return nil }
            return track.relabeled(albumTitle: title, artist: artist)
        }
        let tracks = TrackOrdering.ordered(
            merged,
            number: { $0.trackNumber },
            path: { $0.fileURL.path },
            title: { $0.title }
        )
        return Album(
            title: title,
            artist: artist,
            artwork: canonical.artwork,
            tracks: tracks,
            year: year,
            genre: genre
        )
    }
}
