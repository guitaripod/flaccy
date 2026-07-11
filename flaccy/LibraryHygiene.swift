import Foundation

/// Shared library-hygiene primitives: edition-aware title/artist normalization,
/// duplicate-track grouping, and album-variation consolidation. This is the
/// single source of truth reused by wantlist ownership matching and the desktop
/// "Clean Up Library" feature; the Linux app mirrors this exact spec in
/// `linux/src/hygiene.rs`, so any change here must be reflected there.
nonisolated enum LibraryHygiene {

    static let wantlistKeywords: Set<String> = [
        "deluxe", "edition", "remaster", "bonus", "expanded", "anniversary",
        "special", "extended", "complete", "reissue", "version", "collector",
        "platinum", "legacy", "super", "tour", "feat", "ft.", "with", "explicit",
        "clean", "mono", "stereo", "single", "ep",
    ]

    /// The consolidation set intentionally drops `single`, `ep`, `with`, `feat`,
    /// `ft.` and `version` so a standalone single or an acoustic/live version is
    /// never silently folded into the album; `bonus` still catches "Bonus Track
    /// Version". It adds past-tense/plural edition forms the exact-word matcher
    /// would otherwise miss ("Remastered", "Remixes") since those are among the
    /// most common variation suffixes.
    static let consolidationKeywords: Set<String> =
        wantlistKeywords
        .subtracting(["single", "ep", "with", "feat", "ft.", "version"])
        .union(["remastered", "remasters", "remix", "remixed", "remixes", "reissued"])

    /// The lead artist of a possibly-collaborative credit: the portion before
    /// the first multi-artist separator, with any trailing "feat."/"featuring"
    /// clause stripped. Only splits on separators that unambiguously join
    /// artists (";", "/", "×") so single names containing "&" or "," ("Corvid &
    /// Crane", "Earth, Wind & Fire") are preserved.
    static func primaryArtist(_ raw: String) -> String {
        var name = raw
        for separator in [";", " / ", " × ", " x ", " & ", " + ", " vs. ", " vs ", " feat. ", " feat ",
                          " ft. ", " ft ", " featuring ", " (feat.", " (ft.", " (featuring", " with "] {
            if let range = name.range(of: separator, options: [.caseInsensitive]) {
                name = String(name[..<range.lowerBound])
            }
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed
    }

    /// Case-insensitive grouping key for an artist credit, folding both
    /// collaborators and casing variants ("deadmau5" / "Deadmau5") together.
    static func artistKey(_ credit: String) -> String {
        primaryArtist(credit).lowercased()
    }

    static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var result = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.append(scalar)
        }
        return String(result)
    }

    static func baseTitle(_ raw: String, keywords: Set<String> = wantlistKeywords) -> String {
        var title = stripDecoratedBrackets(from: raw.lowercased(), keywords: keywords)
        for separator in [" - ", ": ", " – "] {
            if let range = title.range(of: separator),
               containsEditionKeyword(String(title[range.upperBound...]), keywords: keywords) {
                title = String(title[..<range.lowerBound])
            }
        }
        return normalize(title)
    }

    static func consolidationBaseTitle(_ raw: String) -> String {
        baseTitle(raw, keywords: consolidationKeywords)
    }

    static func matchKey(title: String, artist: String, keywords: Set<String> = wantlistKeywords) -> String {
        normalize(artist) + "\u{0}" + baseTitle(title, keywords: keywords)
    }

    static func consolidationKey(title: String, artist: String) -> String {
        normalize(artist) + "\u{0}" + consolidationBaseTitle(title)
    }

    private static func stripDecoratedBrackets(from value: String, keywords: Set<String>) -> String {
        var result = value
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] {
            var searchStart = result.startIndex
            while let openRange = result.range(of: open, range: searchStart..<result.endIndex),
                  let closeRange = result.range(of: close, range: openRange.upperBound..<result.endIndex) {
                let segment = String(result[openRange.upperBound..<closeRange.lowerBound])
                if containsEditionKeyword(segment, keywords: keywords) {
                    result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                    searchStart = result.startIndex
                } else {
                    searchStart = closeRange.upperBound
                }
            }
        }
        return result
    }

    private static func containsEditionKeyword(_ segment: String, keywords: Set<String>) -> Bool {
        let words = segment.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.contains { keywords.contains($0) }
            || (keywords.contains("ft.") && segment.lowercased().contains("ft."))
    }

    // MARK: Duplicate detection

    static func isLossless(_ codec: String?) -> Bool {
        guard let codec else { return false }
        return ["FLAC", "ALAC", "WAV", "AIFF", "AIF"].contains(codec.uppercased())
    }

    static func duplicateKey(_ track: Track) -> String {
        [
            normalize(track.artist),
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

    // MARK: Album-variation consolidation

    struct AlbumVariant: Sendable, Hashable {
        let title: String
        let artist: String
    }

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
            total + (isLossless(track.codec) ? 1_000_000_000 : 0)
                + (track.bitDepth ?? 0) * 1_000_000
                + (track.sampleRate ?? 0)
        }
    }
}
