import Combine
import Foundation

nonisolated enum WantlistSection: Int, Hashable, CaseIterable {
    case newReleases
    case albums
    case gaps
    case upgrades
    case tracks
    case discoverArtists
    case discoverAlbums

    var headerTitle: String {
        switch self {
        case .newReleases: "New Releases"
        case .albums: "Albums to Get"
        case .gaps: "Complete These Albums"
        case .upgrades: "Upgrade to Lossless"
        case .tracks: "Songs to Get"
        case .discoverArtists: "Artists to Explore"
        case .discoverAlbums: "Albums to Explore"
        }
    }
}

nonisolated enum WantlistFilter: Int, CaseIterable {
    case all, albums, songs, discover, releases, upgrades

    var title: String {
        switch self {
        case .all: "All"
        case .albums: "Albums"
        case .songs: "Songs"
        case .discover: "Discover"
        case .releases: "New"
        case .upgrades: "Upgrades"
        }
    }

    var sections: Set<WantlistSection> {
        switch self {
        case .all: Set(WantlistSection.allCases)
        case .albums: [.albums, .gaps]
        case .songs: [.tracks]
        case .discover: [.discoverArtists, .discoverAlbums]
        case .releases: [.newReleases]
        case .upgrades: [.upgrades]
        }
    }
}

nonisolated struct WantlistRowMeta: Hashable, Sendable {
    let normKey: String
    let reason: String
    let source: String
    let storeURL: String?
}

nonisolated enum WantlistItem: Hashable {
    case album(AlbumItem, WantlistRowMeta)
    case track(TrackItem, WantlistRowMeta)
    case artist(RecapArtistItem, WantlistRowMeta)
}

nonisolated struct WantlistData: Sendable {
    var sections: [(section: WantlistSection, items: [WantlistItem])] = []

    var isEmpty: Bool { sections.allSatisfy { $0.items.isEmpty } }

    func filtered(by filter: WantlistFilter) -> [(section: WantlistSection, items: [WantlistItem])] {
        sections.filter { filter.sections.contains($0.section) && !$0.items.isEmpty }
    }
}

/// Edition-aware ownership index: local and Last.fm names are reduced to a
/// base title with deluxe/remaster/bonus-style decorations stripped, so owning
/// any edition of an album (or a feat./remaster variant of a track) counts as
/// owning it. Album matching additionally tolerates one base title being a
/// prefix of the other within the same artist.
nonisolated struct WantlistOwnership: Sendable {
    private let albumTitlesByArtist: [String: [String]]
    private let trackKeys: Set<String>
    private let artists: Set<String>
    private let trackCountByAlbumKey: [String: Int]

    private static let editionKeywords = [
        "deluxe", "edition", "remaster", "bonus", "expanded", "anniversary",
        "special", "extended", "complete", "reissue", "version", "collector",
        "platinum", "legacy", "super", "tour", "feat", "ft.", "with", "explicit",
        "clean", "mono", "stereo", "single", "ep",
    ]

    init(albums: [Album], tracks: [Track]) {
        var byArtist: [String: [String]] = [:]
        for album in albums {
            byArtist[Self.normalize(album.artist), default: []].append(Self.baseTitle(album.title))
        }
        albumTitlesByArtist = byArtist
        trackKeys = Set(tracks.map { Self.normalize($0.artist) + "\u{0}" + Self.baseTitle($0.title) })
        artists = Set(albums.map { Self.normalize($0.artist) })
        var counts: [String: Int] = [:]
        for track in tracks {
            counts[Self.matchKey(title: track.albumTitle, artist: track.artist), default: 0] += 1
        }
        trackCountByAlbumKey = counts
    }

    static func matchKey(title: String, artist: String) -> String {
        normalize(artist) + "\u{0}" + baseTitle(title)
    }

    func ownsAlbum(name: String, artist: String) -> Bool {
        guard let owned = albumTitlesByArtist[Self.normalize(artist)] else { return false }
        let base = Self.baseTitle(name)
        guard !base.isEmpty else { return true }
        return owned.contains { candidate in
            candidate == base
                || (base.count >= 4 && candidate.hasPrefix(base))
                || (candidate.count >= 4 && base.hasPrefix(candidate))
        }
    }

    func ownsTrack(title: String, artist: String) -> Bool {
        trackKeys.contains(Self.normalize(artist) + "\u{0}" + Self.baseTitle(title))
    }

    func hasArtist(_ name: String) -> Bool {
        artists.contains(Self.normalize(name))
    }

    func ownedTrackCount(albumName: String, artist: String) -> Int {
        trackCountByAlbumKey[Self.matchKey(title: albumName, artist: artist)] ?? 0
    }

    private static func baseTitle(_ raw: String) -> String {
        var title = stripDecoratedBrackets(from: raw.lowercased())
        for separator in [" - ", ": ", " – "] {
            if let range = title.range(of: separator),
               containsEditionKeyword(String(title[range.upperBound...])) {
                title = String(title[..<range.lowerBound])
            }
        }
        return normalize(title)
    }

    private static func stripDecoratedBrackets(from value: String) -> String {
        var result = value
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] {
            var searchStart = result.startIndex
            while let openRange = result.range(of: open, range: searchStart..<result.endIndex),
                  let closeRange = result.range(of: close, range: openRange.upperBound..<result.endIndex) {
                let segment = String(result[openRange.upperBound..<closeRange.lowerBound])
                if containsEditionKeyword(segment) {
                    result.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                    searchStart = result.startIndex
                } else {
                    searchStart = closeRange.upperBound
                }
            }
        }
        return result
    }

    private static func containsEditionKeyword(_ segment: String) -> Bool {
        let words = segment.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.contains { editionKeywords.contains($0) }
            || segment.lowercased().contains("ft.")
    }

    private static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var result = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.append(scalar)
        }
        return String(result)
    }
}

/// Renders the persisted wantlist instantly, then refreshes suggestions from
/// Last.fm, local gap/quality analysis, discovery, and the new-release watch
/// in the background, merging into the store and re-publishing.
final class WantlistViewModel {

    let dataPublisher = CurrentValueSubject<WantlistData?, Never>(nil)
    let loadingPublisher = PassthroughSubject<Bool, Never>()

    private let lastFM = LastFMService.shared
    private let service = WantlistService.shared
    private var loadGeneration = 0

    private nonisolated static let missingAlbumLimit = 18
    private nonisolated static let missingTrackLimit = 20
    private nonisolated static let discoverArtistLimit = 10
    private nonisolated static let discoverAlbumLimit = 9
    private nonisolated static let seedArtistCount = 6

    var isAvailable: Bool { lastFM.isAuthenticated }

    /// Instant render from the store; network refresh only when asked.
    func loadCached() {
        dataPublisher.send(assembleData())
    }

    func refresh() {
        loadGeneration += 1
        let generation = loadGeneration
        loadingPublisher.send(true)

        let ownership = WantlistOwnership(albums: Library.shared.albums, tracks: Library.shared.allTracks)
        let localAlbums = Library.shared.albums
        let localTopArtists = topLocalArtists()

        Task { [weak self] in
            guard let self else { return }
            var suggestions = WantlistService.localSuggestions(albums: localAlbums)
            if self.isAvailable {
                suggestions += await self.remoteSuggestions(ownership: ownership)
            }
            self.service.merge(suggestions: suggestions)
            self.service.resolveAgainstLibrary()
            _ = await self.service.refreshNewReleasesIfStale(topArtists: localTopArtists)
            await MainActor.run {
                guard generation == self.loadGeneration else { return }
                self.dataPublisher.send(self.assembleData())
                self.loadingPublisher.send(false)
            }
        }
    }

    // MARK: Assembly from store

    private func assembleData() -> WantlistData {
        let wanted = service.wantedItems()
        let releases = service.cachedNewReleases()

        var grouped: [WantlistSection: [WantlistItem]] = [:]

        grouped[.newReleases] = releases.enumerated().map { offset, release in
            let meta = WantlistRowMeta(
                normKey: WantlistService.normKey(kind: .album, title: release.albumTitle, artist: release.artist),
                reason: "Released \(Self.relativeDate(release.releaseDate))",
                source: "release",
                storeURL: release.storeURL
            )
            return .album(
                AlbumItem(rank: offset + 1, name: release.albumTitle, artist: release.artist, playCount: 0, imageURL: release.imageURL),
                meta
            )
        }

        for record in wanted {
            let meta = WantlistRowMeta(normKey: record.normKey, reason: record.reason, source: record.source, storeURL: nil)
            switch (WantlistKind(rawValue: record.kind), WantlistSource(rawValue: record.source)) {
            case (.album, .gap):
                grouped[.gaps, default: []].append(albumItem(record, rank: grouped[.gaps]?.count ?? 0, meta: meta))
            case (.album, .upgrade):
                grouped[.upgrades, default: []].append(albumItem(record, rank: grouped[.upgrades]?.count ?? 0, meta: meta))
            case (.album, .discovery):
                grouped[.discoverAlbums, default: []].append(albumItem(record, rank: grouped[.discoverAlbums]?.count ?? 0, meta: meta))
            case (.album, _):
                grouped[.albums, default: []].append(albumItem(record, rank: grouped[.albums]?.count ?? 0, meta: meta))
            case (.track, _):
                let item = TrackItem(
                    rank: (grouped[.tracks]?.count ?? 0) + 1, name: record.title,
                    artist: record.artist, playCount: record.playCount
                )
                grouped[.tracks, default: []].append(.track(item, meta))
            case (.artist, _):
                let item = RecapArtistItem(rank: (grouped[.discoverArtists]?.count ?? 0) + 1, name: record.artist, playCount: 0)
                grouped[.discoverArtists, default: []].append(.artist(item, meta))
            case (nil, _):
                break
            }
        }

        var data = WantlistData()
        data.sections = WantlistSection.allCases.compactMap { section in
            guard let items = grouped[section], !items.isEmpty else { return nil }
            return (section, items)
        }
        return data
    }

    private func albumItem(_ record: WantlistRecord, rank: Int, meta: WantlistRowMeta) -> WantlistItem {
        .album(
            AlbumItem(rank: rank + 1, name: record.title, artist: record.artist, playCount: record.playCount, imageURL: record.imageURL),
            meta
        )
    }

    private nonisolated static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Local suggestions (gaps + upgrades)

    private func topLocalArtists() -> [String] {
        var plays: [String: Int] = [:]
        for track in Library.shared.allTracks {
            plays[track.artist, default: 0] += 1
        }
        return plays.sorted { $0.value > $1.value }.map(\.key)
    }

    // MARK: Remote suggestions

    private nonisolated func remoteSuggestions(ownership: WantlistOwnership) async -> [WantlistRecord] {
        async let topAlbums = lastFM.fetchTopAlbums(period: .allTime, limit: 50)
        async let topTracks = lastFM.fetchTopTracks(period: .allTime, limit: 50)
        async let lovedTracks = lastFM.fetchLovedTracks(page: 1, limit: 200)
        async let topArtists = lastFM.fetchTopArtists(period: .allTime, limit: 20)
        let (albums, tracks, loved, artists) = await (topAlbums, topTracks, lovedTracks.tracks, topArtists)

        let now = Date()
        var records: [WantlistRecord] = []

        for album in albums.filter({ !ownership.ownsAlbum(name: $0.name, artist: $0.artistName) }).prefix(Self.missingAlbumLimit) {
            let ownedTracks = ownership.ownedTrackCount(albumName: album.name, artist: album.artistName)
            var reason = "\(album.playCount) plays on Last.fm"
            if ownedTracks > 0 { reason += " · you own \(ownedTracks) of its tracks" }
            records.append(WantlistRecord(
                normKey: WantlistService.normKey(kind: .album, title: album.name, artist: album.artistName),
                kind: WantlistKind.album.rawValue, title: album.name, artist: album.artistName,
                imageURL: album.imageURL, state: WantlistState.wanted.rawValue, source: WantlistSource.history.rawValue,
                score: Double(album.playCount) * (1 + 0.15 * Double(ownedTracks)),
                reason: reason, playCount: album.playCount, addedAt: now, resolvedAt: nil, acknowledged: false
            ))
        }

        var seenTracks = Set<String>()
        for track in tracks where !ownership.ownsTrack(title: track.name, artist: track.artistName) {
            let key = WantlistOwnership.matchKey(title: track.name, artist: track.artistName)
            guard seenTracks.insert(key).inserted else { continue }
            records.append(WantlistRecord(
                normKey: WantlistService.normKey(kind: .track, title: track.name, artist: track.artistName),
                kind: WantlistKind.track.rawValue, title: track.name, artist: track.artistName,
                imageURL: nil, state: WantlistState.wanted.rawValue, source: WantlistSource.history.rawValue,
                score: Double(track.playCount), reason: "\(track.playCount) plays on Last.fm",
                playCount: track.playCount, addedAt: now, resolvedAt: nil, acknowledged: false
            ))
            if seenTracks.count >= Self.missingTrackLimit { break }
        }
        for track in loved where !ownership.ownsTrack(title: track.name, artist: track.artist) {
            let key = WantlistOwnership.matchKey(title: track.name, artist: track.artist)
            guard seenTracks.insert(key).inserted else { continue }
            records.append(WantlistRecord(
                normKey: WantlistService.normKey(kind: .track, title: track.name, artist: track.artist),
                kind: WantlistKind.track.rawValue, title: track.name, artist: track.artist,
                imageURL: nil, state: WantlistState.wanted.rawValue, source: WantlistSource.loved.rawValue,
                score: 500, reason: "Loved on Last.fm",
                playCount: 0, addedAt: now, resolvedAt: nil, acknowledged: false
            ))
            if seenTracks.count >= Self.missingTrackLimit + 10 { break }
        }

        records += await discoverySuggestions(seeds: artists, ownership: ownership, now: now)
        return records
    }

    /// Scores each similar-artist candidate as Σ match × log(1 + seed plays)
    /// across all seeds that suggested it, so an artist adjacent to several
    /// heavily-played favorites outranks a strong match to a minor one.
    private nonisolated func discoverySuggestions(
        seeds: [ChartArtist],
        ownership: WantlistOwnership,
        now: Date
    ) async -> [WantlistRecord] {
        let seedArtists = Array(seeds.prefix(Self.seedArtistCount))
        guard !seedArtists.isEmpty else { return [] }

        let knownNames = Set(seeds.map { WantlistOwnership.matchKey(title: "", artist: $0.name) })
        var scores: [String: (name: String, score: Double, topSeed: String, topContribution: Double)] = [:]

        await withTaskGroup(of: (Int, [(name: String, match: Double)]).self) { group in
            for (offset, seed) in seedArtists.enumerated() {
                group.addTask { [lastFM] in
                    (offset, await lastFM.fetchSimilarArtists(artist: seed.name, limit: 20))
                }
            }
            for await (offset, similar) in group {
                let seed = seedArtists[offset]
                let weight = log(1 + Double(seed.playCount))
                for candidate in similar {
                    let key = WantlistOwnership.matchKey(title: "", artist: candidate.name)
                    guard !knownNames.contains(key), !ownership.hasArtist(candidate.name) else { continue }
                    let contribution = candidate.match * weight
                    if var existing = scores[key] {
                        existing.score += contribution
                        if contribution > existing.topContribution {
                            existing.topSeed = seed.name
                            existing.topContribution = contribution
                        }
                        scores[key] = existing
                    } else {
                        scores[key] = (candidate.name, contribution, seed.name, contribution)
                    }
                }
            }
        }

        let ranked = scores.values.sorted { $0.score > $1.score }.prefix(Self.discoverArtistLimit)
        var records: [WantlistRecord] = ranked.map { entry in
            WantlistRecord(
                normKey: WantlistService.normKey(kind: .artist, title: "", artist: entry.name),
                kind: WantlistKind.artist.rawValue, title: entry.name, artist: entry.name,
                imageURL: nil, state: WantlistState.wanted.rawValue, source: WantlistSource.discovery.rawValue,
                score: entry.score, reason: "Because you play \(entry.topSeed)",
                playCount: 0, addedAt: now, resolvedAt: nil, acknowledged: false
            )
        }

        var albumCount = 0
        for entry in ranked {
            guard albumCount < Self.discoverAlbumLimit else { break }
            let top = await lastFM.fetchArtistTopAlbums(artist: entry.name, limit: 3)
            guard let album = top.first(where: { !ownership.ownsAlbum(name: $0.name, artist: $0.artistName) }) else { continue }
            records.append(WantlistRecord(
                normKey: WantlistService.normKey(kind: .album, title: album.name, artist: album.artistName),
                kind: WantlistKind.album.rawValue, title: album.name, artist: album.artistName,
                imageURL: album.imageURL, state: WantlistState.wanted.rawValue, source: WantlistSource.discovery.rawValue,
                score: entry.score, reason: "Because you play \(entry.topSeed)",
                playCount: 0, addedAt: now, resolvedAt: nil, acknowledged: false
            ))
            albumCount += 1
        }
        return records
    }
}
