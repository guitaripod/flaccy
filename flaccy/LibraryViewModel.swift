import Combine
import FlaccyCore

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

nonisolated enum LibraryItem: Hashable, Sendable {
    case album(Album)
    case recentAlbum(Album)
    case song(Track)
    case artist(ArtistItem)
    case playlist(PlaylistItem)
    case suggestedPlaylist(SuggestedPlaylist)
    case charts
    case wantlist

    /// The identity a diffable snapshot keys an album row by: the earliest file
    /// path the album owns, which no amount of retitling moves.
    ///
    /// Keying by title and artist — which is what `Album`'s own `Hashable` does
    /// — would make every AI correction during the Debut's second act a delete
    /// followed by an insert, and the grid would tear under a reader who is
    /// already scrolling it. Keyed by a path, the same correction is a move.
    nonisolated static func identity(of album: Album) -> String {
        album.tracks.lazy.map(\.fileURL.absoluteString).min() ?? album.id
    }

    /// What a row draws, so a snapshot can ask for a reconfigure when the
    /// identity held but the words on screen changed.
    nonisolated static func renderSignature(of album: Album) -> String {
        "\(album.title)\u{1F}\(album.artist)\u{1F}\(album.year ?? "")\u{1F}\(album.genre ?? "")"
    }

    nonisolated static func == (lhs: LibraryItem, rhs: LibraryItem) -> Bool {
        switch (lhs, rhs) {
        case (.album(let a), .album(let b)), (.recentAlbum(let a), .recentAlbum(let b)):
            return identity(of: a) == identity(of: b)
        case (.song(let a), .song(let b)): return a == b
        case (.artist(let a), .artist(let b)): return a == b
        case (.playlist(let a), .playlist(let b)): return a == b
        case (.suggestedPlaylist(let a), .suggestedPlaylist(let b)): return a == b
        case (.charts, .charts), (.wantlist, .wantlist): return true
        default: return false
        }
    }

    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .album(let album):
            hasher.combine(0)
            hasher.combine(Self.identity(of: album))
        case .recentAlbum(let album):
            hasher.combine(1)
            hasher.combine(Self.identity(of: album))
        case .song(let track):
            hasher.combine(2)
            hasher.combine(track)
        case .artist(let artist):
            hasher.combine(3)
            hasher.combine(artist)
        case .playlist(let playlist):
            hasher.combine(4)
            hasher.combine(playlist)
        case .suggestedPlaylist(let suggestion):
            hasher.combine(5)
            hasher.combine(suggestion)
        case .charts:
            hasher.combine(6)
        case .wantlist:
            hasher.combine(7)
        }
    }
}

nonisolated struct ArtistItem: Hashable, Sendable {
    let name: String
    let albumCount: Int
    let artwork: PlatformImage?

    nonisolated static func == (lhs: ArtistItem, rhs: ArtistItem) -> Bool {
        lhs.name == rhs.name
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

nonisolated struct PlaylistItem: Hashable, Sendable {
    let id: Int64
    let name: String
    let trackCount: Int

    nonisolated static func == (lhs: PlaylistItem, rhs: PlaylistItem) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

final class LibraryViewModel {

    /// Guards sort/meta caches shared by the background snapshot queue and main.
    private let cacheLock = NSRecursiveLock()

    enum Segment: Int, CaseIterable {
        case albums
        case songs
        case artists
        case playlists
    }

    enum AlbumSort: String, CaseIterable {
        case title, artist, year, recentlyAdded, recentlyPlayed

        var displayName: String {
            switch self {
            case .title: String(localized: "Title")
            case .artist: String(localized: "Artist")
            case .year: String(localized: "Year")
            case .recentlyAdded: String(localized: "Recently Added")
            case .recentlyPlayed: String(localized: "Recently Played")
            }
        }

        var icon: String {
            switch self {
            case .title: "textformat.abc"
            case .artist: "person"
            case .year: "calendar"
            case .recentlyAdded: "clock.badge.plus"
            case .recentlyPlayed: "clock.arrow.circlepath"
            }
        }
    }

    enum SongSort: String, CaseIterable {
        case title, artist, mostScrobbled, recentlyPlayed, dateAdded

        var displayName: String {
            switch self {
            case .title: String(localized: "Title")
            case .artist: String(localized: "Artist")
            case .mostScrobbled: String(localized: "Most Played")
            case .recentlyPlayed: String(localized: "Recently Played")
            case .dateAdded: String(localized: "Date Added")
            }
        }

        var icon: String {
            switch self {
            case .title: "textformat.abc"
            case .artist: "person"
            case .mostScrobbled: "flame"
            case .recentlyPlayed: "clock"
            case .dateAdded: "calendar"
            }
        }
    }

    enum ArtistSort: String, CaseIterable {
        case name, albumCount, mostPlayed, recentlyPlayed

        var displayName: String {
            switch self {
            case .name: String(localized: "Name")
            case .albumCount: String(localized: "Album Count")
            case .mostPlayed: String(localized: "Most Played")
            case .recentlyPlayed: String(localized: "Recently Played")
            }
        }

        var icon: String {
            switch self {
            case .name: "textformat.abc"
            case .albumCount: "number"
            case .mostPlayed: "flame"
            case .recentlyPlayed: "clock.arrow.circlepath"
            }
        }
    }

    typealias Snapshot = NSDiffableDataSourceSnapshot<Int, LibraryItem>

    private let library: LibraryProviding
    private let audioPlayer: AudioPlaying

    let snapshotPublisher = PassthroughSubject<Snapshot, Never>()
    let miniPlayerStatePublisher = PassthroughSubject<MiniPlayerState?, Never>()
    let loadingPublisher = PassthroughSubject<Bool, Never>()
    let loadStatePublisher = PassthroughSubject<LibraryLoadState, Never>()

    struct MiniPlayerState {
        let track: Track
        let isPlaying: Bool
    }

    /// What launch chrome looks like to the UI: which surface the router asked
    /// for, and everything that surface could need to draw itself.
    ///
    /// There is deliberately no `showsFullScreen` / `showsBanner` / `hasLibrary`
    /// here. Those were two booleans derived at Combine delivery time, and a
    /// restored library flipping one of them between snapshots is exactly how
    /// the debut ring got painted once at 1% and then crossfaded away frozen.
    /// A client may render `surface` and nothing else.
    struct LibraryLoadState {
        let surface: LibrarySurface
        let progress: LibraryLoadProgress
        let fraction: Double
        let job: EnrichmentJobProgress
    }

    /// The state to paint at bind time, before a single notification has
    /// arrived — without it the first frame is an empty label at 0%.
    ///
    /// A launch that has loaded nothing yet reports `.openingLibrary` rather
    /// than `.idle`, because that is what the very next frame will be. Routing
    /// an idle phase here would take the Debut down for exactly one frame and
    /// raise it again, which is the flash this whole path exists to remove.
    var currentLoadState: LibraryLoadState {
        let load = library.loadProgress
        latestLoad = load.isActive || !library.albums.isEmpty
            ? load
            : LibraryLoadProgress(phase: .openingLibrary)
        latestFraction = library.loadFraction
        latestJob = EnrichmentCoordinator.shared.progress
        return routedState()
    }

    /// How many covers the Debut's mosaic is allowed to decode: what it can hold
    /// on screen plus what it can queue for rotation, so a three-thousand-album
    /// first launch decodes sixty thumbnails, not three thousand.
    static let mosaicCoverBudget = 60

    /// The albums whose covers fuel the Debut's mosaic once the library has been
    /// built. During Act I the covers arrive from `Library.albumCoversHoisted`
    /// instead, because this list is empty until the phase after the one the
    /// mosaic narrates.
    func mosaicAlbums() -> [Album] {
        Array(library.albums.prefix(Self.mosaicCoverBudget))
    }

    /// Which act the Debut is in. Read by the surface immediately after it
    /// receives a state, so the act and the snapshot it belongs to are the same
    /// pair the router just decided on.
    private(set) var debutAct: LibraryDebutAct = .indexing

    /// True while the Debut still has something to show but the library has
    /// become browsable, so the showpiece belongs in a sheet the reader opens
    /// rather than across the screen they are already using.
    var debutIsPending: Bool { surfaceRouter.debutIsPending }

    nonisolated private enum LibrarySignal: Sendable {
        case load(LibraryLoadProgress, Double)
        case job(EnrichmentJobProgress)
        case tick
    }

    private var surfaceCancellable: AnyCancellable?
    private var surfaceRouter = LibrarySurfaceRouter()
    private var debutDirector = LibraryDebutDirector()
    private var latestLoad: LibraryLoadProgress = .idle
    private var latestFraction: Double = 0
    private var latestJob: EnrichmentJobProgress = .idle
    private var finishingStartedAt: Date?
    private var heardFromJob = false
    private let debutTick = PassthroughSubject<Void, Never>()
    private var debutTicker: Task<Void, Never>?
    private lazy var debutCompleted: Bool = Self.readDebutCompleted()

    private(set) var currentSegment: Segment = .albums
    private var searchQuery: String = ""
    var isSearching: Bool { !searchQuery.isEmpty }
    private(set) var albumSort: AlbumSort = AlbumSort(rawValue: UserDefaults.standard.string(forKey: "albumSort") ?? "") ?? .title
    private(set) var songSort: SongSort = SongSort(rawValue: UserDefaults.standard.string(forKey: "songSort") ?? "") ?? .title
    private(set) var scrobbleRange: ChartPeriod = ChartPeriod(rawValue: UserDefaults.standard.string(forKey: "songScrobbleRange") ?? "") ?? .allTime
    private(set) var artistSort: ArtistSort = ArtistSort(rawValue: UserDefaults.standard.string(forKey: "artistSort") ?? "") ?? .name
    private(set) var layoutMode: LibraryLayoutMode = .persisted
    private(set) var filter: LibraryFilter = .persisted

    private struct TrackMeta {
        let track: Track
        let dateAdded: Date
        let lastPlayed: Date?
    }

    private var cachedMeta: [String: TrackMeta]?
    private var cachedScrobbleCounts: (period: ChartPeriod, counts: [String: Int])?
    private var scrobbleCountsWarming = false
    private var cachedRediscover: (keys: Set<String>, albums: [Album])?
    private let recentlyWindow: TimeInterval = 60 * 60 * 24 * 30
    private let rediscoverMinDays = 14
    private let rediscoverMinPlays = 2

    private var trackMeta: [String: TrackMeta] {
        cacheLock.lock()
        if let cached = cachedMeta {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        var map = [String: TrackMeta]()
        if let records = try? DatabaseManager.shared.fetchAllTracks() {
            map.reserveCapacity(records.count)
            for record in records {
                map[record.fileURL] = TrackMeta(
                    track: Track.from(record: record, artwork: nil),
                    dateAdded: record.dateAdded,
                    lastPlayed: record.lastPlayed
                )
            }
        }
        cacheLock.lock()
        cachedMeta = map
        cacheLock.unlock()
        return map
    }

    #if os(macOS)
    private static var documentsPath: String { LibraryPaths.root.path }
    #else
    private static let documentsPath = LibraryPaths.root.path
    #endif

    private func relativePath(for url: URL) -> String {
        let docs = Self.documentsPath
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(docs) else { return url.lastPathComponent }
        let relative = String(path.dropFirst(docs.count))
        return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
    }

    /// Returns the codec-populated variant of a lightweight library track so its
    /// `qualityBadge`/`isLossless` resolve; falls back to the original if unknown.
    /// Tracks loaded via the light path already carry codec fields — skip the
    /// full-table meta lookup in that common case (it was hitching every Songs sort).
    private func hydrate(_ track: Track) -> Track {
        if track.codec != nil { return track }
        return trackMeta[relativePath(for: track.fileURL)]?.track ?? track
    }

    /// Faster than `localizedCaseInsensitiveCompare` across thousands of rows;
    /// library lists are not locale-sensitive catalogue sorts.
    private static func titleOrder(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedAscending
    }

    private func meta(for track: Track) -> TrackMeta? {
        trackMeta[relativePath(for: track.fileURL)]
    }

    /// The number of local plays for a track over the selected range, or nil
    /// when not yet warmed or never played. Reads only the warmed cache so it
    /// is cheap enough to call for every visible cell.
    func scrobbleCount(for track: Track) -> Int? {
        guard let cached = cachedScrobbleCounts, cached.period == scrobbleRange else { return nil }
        let count = cached.counts[LastFMStatsService.trackKey(track.title, track.artist)] ?? 0
        return count > 0 ? count : nil
    }

    /// Warms the play-count cache off-main the first time the Songs segment
    /// needs it, then republishes so cells pick up their counts without hitching.
    func warmScrobbleCountsIfNeeded() {
        guard currentSegment == .songs else { return }
        if let cached = cachedScrobbleCounts, cached.period == scrobbleRange { return }
        guard !scrobbleCountsWarming else { return }
        scrobbleCountsWarming = true
        let range = scrobbleRange
        Task.detached(priority: .userInitiated) { [weak self] in
            let counts = LastFMStatsService.shared.scrobbleCounts(period: range)
            await MainActor.run {
                guard let self else { return }
                self.scrobbleCountsWarming = false
                self.cachedScrobbleCounts = (range, counts)
                if self.currentSegment == .songs {
                    if self.songSort == .mostScrobbled { self.cachedSortedSongs = nil }
                    self.publishSnapshot()
                }
            }
        }
    }

    private var cachedRepresentativeTracks = [String: Track]()
    private var cachedFirstAlbumByArtist: [String: Album]?

    /// The album's best representative track for a quality badge: lossless first,
    /// then highest bit-depth and sample-rate. Cached per album because cells
    /// request it on every dequeue during a scroll.
    func representativeTrack(for album: Album) -> Track? {
        let key = "\(album.title)|\(album.artist)"
        cacheLock.lock()
        if let cached = cachedRepresentativeTracks[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        // Prefer already-hydrated codec fields; only fall back to meta for gaps.
        let best = album.tracks.map { track in
            track.codec != nil ? track : hydrate(track)
        }.max { qualityRank($0) < qualityRank($1) }
        if let best {
            cacheLock.lock()
            cachedRepresentativeTracks[key] = best
            cacheLock.unlock()
        }
        return best
    }

    /// A representative album for the artist's avatar artwork, resolved through
    /// a lazily built index instead of a per-cell linear scan over all albums.
    func firstAlbum(forArtist name: String) -> Album? {
        if cachedFirstAlbumByArtist == nil {
            cachedFirstAlbumByArtist = Dictionary(
                library.albums.map { ($0.artist, $0) }, uniquingKeysWith: { first, _ in first }
            )
        }
        return cachedFirstAlbumByArtist?[name]
    }

    private var cachedAlbumAdded: [String: Date]?
    private var cachedAlbumPlayed: [String: Date]?

    private func albumDateAddedMap() -> [String: Date] {
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

    private func albumLastPlayedMap() -> [String: Date] {
        if let cached = cachedAlbumPlayed { return cached }
        var map = [String: Date]()
        if let rows = try? DatabaseManager.shared.lastPlayedByAlbum() {
            for row in rows { map["\(row.albumTitle)|\(row.artist)"] = row.lastPlayed }
        }
        cachedAlbumPlayed = map
        return map
    }

    private func qualityRank(_ track: Track) -> Int {
        (track.isLossless ? 1 << 24 : 0) + (track.bitDepth ?? 0) * 100000 + (track.sampleRate ?? 0)
    }

    func isLovedAlbum(_ album: Album) -> Bool {
        LovedTracksService.shared.containsLoved(among: album.tracks)
    }

    /// Albums highly played but not spun recently, ranked by a Longplay-style
    /// negligence score of playCount over days since last play.
    private var rediscover: (keys: Set<String>, albums: [Album]) {
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

    private var cachedSortedAlbums: [Album]?
    private var cachedSortedSongs: [Track]?
    private var cachedSortedArtists: [ArtistItem]?
    private var cachedRecentAlbums: [Album]?
    private var cachedPlaylists: [PlaylistItem]?
    private var cachedSuggestions: [SuggestedPlaylist]?
    private var suggestionsLoading = false
    private var searchDebounceTask: Task<Void, Never>?

    enum EmptyState {
        case none
        case noLibrary
        case noSearchResults(String)
    }

    private(set) var emptyState: EmptyState = .none
    private(set) var visibleSongs: [Track] = []

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
    private func artistPlayCounts() -> [String: Int] {
        var map = [String: Int]()
        for entry in LastFMStatsService.shared.topArtists(period: scrobbleRange, limit: 1000) {
            map[artistMatchKey(entry.name), default: 0] += entry.playCount
        }
        return map
    }

    private func artistLastPlayedMap() -> [String: Date] {
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
            AppLogger.error("Failed to fetch playlists: \(error.localizedDescription)", category: .database)
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

    var artists: [ArtistItem] {
        var seen = [String: ArtistItem]()
        for album in library.albums {
            let display = artistGroupKey(album.artist)
            let key = artistMatchKey(album.artist)
            if let existing = seen[key] {
                seen[key] = ArtistItem(
                    name: existing.name,
                    albumCount: existing.albumCount + 1,
                    artwork: existing.artwork ?? album.artwork
                )
            } else {
                seen[key] = ArtistItem(
                    name: display,
                    albumCount: 1,
                    artwork: album.artwork
                )
            }
        }
        return seen.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    init(library: LibraryProviding = Library.shared, audioPlayer: AudioPlaying = AudioPlayer.shared) {
        self.library = library
        self.audioPlayer = audioPlayer

        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryDidUpdate), name: Library.didUpdateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(trackDidChange), name: AudioPlayer.trackDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackStateDidChange), name: AudioPlayer.playbackStateDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(loadingStateChanged), name: Library.loadingStateChanged, object: nil
        )

        bindLibrarySurface()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Merges the two things that decide launch chrome — the bounded load bar
    /// and the unbounded enrichment job — onto **one** pipeline.
    ///
    /// Two subscriptions would let a job snapshot and the load fraction it
    /// belongs to be applied in either order, and the surface would flicker
    /// between them. Merged, every routing decision sees one consistent pair.
    /// The third source is a tick the Debut needs while it is on screen: the
    /// director's curtain budget and its "the queue drained" test are questions
    /// about elapsed time that no notification will ever ask on its own.
    private func bindLibrarySurface() {
        let load = NotificationCenter.default.publisher(for: Library.progressDidChange)
            .compactMap { notification -> LibrarySignal? in
                guard let progress = notification.userInfo?[Library.ProgressKey.progress] as? LibraryLoadProgress,
                      let fraction = notification.userInfo?[Library.ProgressKey.fraction] as? Double
                else { return nil }
                return .load(progress, fraction)
            }
            .eraseToAnyPublisher()

        let job = NotificationCenter.default.publisher(for: EnrichmentCoordinator.progressDidChange)
            .compactMap { notification -> LibrarySignal? in
                guard let progress = notification.userInfo?[EnrichmentCoordinator.ProgressKey.progress]
                    as? EnrichmentJobProgress else { return nil }
                return .job(progress)
            }
            .eraseToAnyPublisher()

        let tick = debutTick.map { LibrarySignal.tick }.eraseToAnyPublisher()

        surfaceCancellable = Publishers.MergeMany(load, job, tick)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] signal in
                guard let self else { return }
                switch signal {
                case .load(let progress, let fraction):
                    self.latestLoad = progress
                    self.latestFraction = fraction
                case .job(let progress):
                    self.latestJob = progress
                    self.heardFromJob = true
                case .tick:
                    break
                }
                self.loadStatePublisher.send(self.routedState())
            }
    }

    private func routedState() -> LibraryLoadState {
        let surface = surfaceRouter.route(
            load: latestLoad,
            job: latestJob,
            debutCompleted: debutCompleted,
            hasLibrary: !library.albums.isEmpty,
            elapsed: latestJob.startedAt.map { Date().timeIntervalSince($0) } ?? 0
        )
        advanceDebut(on: surface)
        return LibraryLoadState(
            surface: surface, progress: latestLoad, fraction: latestFraction, job: latestJob
        )
    }

    /// Moves the Debut's director forward, and keeps the tick alive only while
    /// there is an act left to reach. Act III is terminal until the card is
    /// dismissed, so the timer stops there rather than polling behind a card.
    private func advanceDebut(on surface: LibrarySurface) {
        guard surface == .debut else {
            stopDebutTicking()
            return
        }
        let elapsedInFinishing = finishingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        debutDirector.advance(
            load: latestLoad,
            job: latestJob,
            albumCount: library.albums.count,
            elapsedInFinishing: elapsedInFinishing,
            jobHeardFrom: jobHasSpoken(elapsedInFinishing: elapsedInFinishing)
        )
        debutAct = debutDirector.act
        if debutAct == .finishing, finishingStartedAt == nil { finishingStartedAt = Date() }
        if debutAct < .summary { startDebutTicking() } else { stopDebutTicking() }
    }

    /// Whether the director may believe a drained queue means the enrichment
    /// job is over.
    ///
    /// The job's snapshot starts life `.idle` with nothing remaining, so the
    /// first evaluation after Act I would otherwise skip the whole AI act
    /// before the coordinator has even counted what is due. The floor keeps a
    /// pass that never reports from stranding the act; the 90 s curtain
    /// remains the ceiling either way.
    private func jobHasSpoken(elapsedInFinishing: TimeInterval) -> Bool {
        heardFromJob || elapsedInFinishing >= Self.jobReportFloor
    }

    private static let jobReportFloor: TimeInterval = 2

    private func startDebutTicking() {
        guard debutTicker == nil else { return }
        debutTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.debutTick.send()
            }
        }
    }

    private func stopDebutTicking() {
        debutTicker?.cancel()
        debutTicker = nil
    }

    /// The figures the summary card reports.
    func debutSummary() async -> LibraryDebutSummary {
        await library.debutSummary()
    }

    /// Whether the AI pass was skipped because there was nothing entitling it.
    ///
    /// Read from the same predicate `AIIdentificationTask` gates itself on, not
    /// from the job's activity: a `needsEntitlement` snapshot is throttled like
    /// any other and can be superseded by the `.idle` that ends the pass, so a
    /// card built from the stream would miss the one moment worth converting on.
    var aiSkippedForEntitlement: Bool {
        PurchaseManager.shared.state == .expired
    }

    /// Writes the once-per-library record and leaves the Debut for good. The
    /// summary is what makes the launch a debut rather than a scan, so it is
    /// persisted before the surface is released, not after.
    func completeDebut(with summary: LibraryDebutSummary) {
        do {
            try DatabaseManager.shared.saveLibraryDebut(summary)
        } catch {
            AppLogger.error("Failed to record library debut: \(error.localizedDescription)", category: .database)
        }
        dismissDebut()
    }

    /// Whether this library has already had its Debut. The startup probe
    /// answers first: a launch that indexed a library but died before the
    /// summary card was dismissed leaves no `libraryDebut` row, and the
    /// controller will not install the debut view for it — so deriving this from
    /// the row alone would latch the router on a surface with nothing to draw
    /// and nothing left to release it. Read once, at bind time, before
    /// `Library.recordIndexedLibrary()` can fire in this same launch.
    private static func readDebutCompleted() -> Bool {
        if LibraryStartupProbe.hadIndexedLibrary { return true }
        return ((try? DatabaseManager.shared.libraryDebut()) ?? nil) != nil
    }

    /// Leaves the Debut without writing one — an empty first build has no
    /// library to be the debut of, and must earn the showpiece next time.
    func dismissDebut() {
        surfaceRouter.releaseDebut()
        debutCompleted = true
        debutAct = .done
        stopDebutTicking()
        loadStatePublisher.send(routedState())
    }

    func loadLibrary() async {
        await library.reload()
    }

    func restorePlaybackState() {
        audioPlayer.restoreQueueState()
    }

    func importFiles(from urls: [URL]) async {
        let outcome = await library.importFiles(from: urls)
        ReviewPrompt.recordImportedTracks(outcome.imported)
    }

    func setAlbumSort(_ sort: AlbumSort) {
        albumSort = sort
        cacheLock.lock()
        cachedSortedAlbums = nil
        cacheLock.unlock()
        UserDefaults.standard.set(sort.rawValue, forKey: "albumSort")
        publishSnapshot()
    }

    func setSongSort(_ sort: SongSort) {
        songSort = sort
        cacheLock.lock()
        cachedSortedSongs = nil
        cacheLock.unlock()
        UserDefaults.standard.set(sort.rawValue, forKey: "songSort")
        warmScrobbleCountsIfNeeded()
        publishSnapshot()
    }

    func setScrobbleRange(_ range: ChartPeriod) {
        guard scrobbleRange != range else { return }
        scrobbleRange = range
        cacheLock.lock()
        cachedScrobbleCounts = nil
        if songSort == .mostScrobbled { cachedSortedSongs = nil }
        cacheLock.unlock()
        UserDefaults.standard.set(range.rawValue, forKey: "songScrobbleRange")
        warmScrobbleCountsIfNeeded()
        publishSnapshot()
    }

    func setArtistSort(_ sort: ArtistSort) {
        artistSort = sort
        cacheLock.lock()
        cachedSortedArtists = nil
        cacheLock.unlock()
        UserDefaults.standard.set(sort.rawValue, forKey: "artistSort")
        publishSnapshot()
    }

    func cycleLayoutMode() {
        layoutMode = layoutMode.next
        layoutMode.persist()
    }

    func setFilter(_ filter: LibraryFilter) {
        guard self.filter != filter else { return }
        self.filter = filter
        filter.persist()
        publishSnapshot()
    }

    /// Rebuilds and republishes the current snapshot without changing state,
    /// e.g. after loved state changes while the Favorites pivot is active.
    func refilter() {
        publishSnapshot()
    }

    func currentSnapshot() -> Snapshot {
        buildSnapshot()
    }

    private var snapshotEpoch = 0
    private let snapshotQueue = DispatchQueue(label: "flaccy.library.snapshot", qos: .userInitiated)

    /// Why the last snapshot was published.
    ///
    /// A list swap replaces every row and is cheaper to reload than to diff, but
    /// a library refresh keeps the same rows — and during the Debut's second act
    /// the AI is renaming albums under a reader who is already scrolling, so
    /// that one has to diff and move rather than tear the grid down.
    enum SnapshotIntent {
        case replaceList
        case refreshLibrary
    }

    private(set) var snapshotIntent: SnapshotIntent = .replaceList

    /// Builds the next snapshot off the main thread so segment switches and
    /// sort changes never stall the segmented control / menu animations.
    private func publishSnapshot(intent: SnapshotIntent = .replaceList) {
        snapshotEpoch &+= 1
        let epoch = snapshotEpoch
        snapshotIntent = intent
        snapshotQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.buildSnapshot()
            DispatchQueue.main.async {
                guard epoch == self.snapshotEpoch else { return }
                self.snapshotPublisher.send(snapshot)
            }
        }
    }

    /// Warm the inactive list caches in the background after a library load so
    /// the first switch to Songs/Artists is a cache hit.
    private func prewarmSortCaches() {
        snapshotQueue.async { [weak self] in
            guard let self else { return }
            _ = self.sortedAlbums
            _ = self.sortedSongs
            _ = self.sortedArtists
            _ = self.songSearchKeys()
        }
    }

    func availableFilters() -> [LibraryFilter] {
        LibraryFilter.allCases.filter { $0.isAvailable(in: currentSegment) }
    }

    var rediscoverAlbums: [Album] {
        rediscover.albums
    }

    private func filteredAlbums(_ albums: [Album]) -> [Album] {
        switch filter {
        case .all:
            return albums
        case .lossless:
            return albums.filter { representativeTrack(for: $0)?.isLossless == true }
        case .favorites:
            return albums.filter { isLovedAlbum($0) }
        case .recentlyAdded:
            let added = albumDateAddedMap()
            let cutoff = Date().addingTimeInterval(-recentlyWindow)
            let sorted = albums.sorted { (added["\($0.title)|\($0.artist)"] ?? .distantPast) > (added["\($1.title)|\($1.artist)"] ?? .distantPast) }
            let recent = sorted.filter { (added["\($0.title)|\($0.artist)"] ?? .distantPast) >= cutoff }
            return recent.count >= 6 ? recent : Array(sorted.prefix(24))
        case .recentlyPlayed:
            let played = albumLastPlayedMap()
            let cutoff = Date().addingTimeInterval(-recentlyWindow)
            let sorted = albums.filter { played["\($0.title)|\($0.artist)"] != nil }
                .sorted { (played["\($0.title)|\($0.artist)"] ?? .distantPast) > (played["\($1.title)|\($1.artist)"] ?? .distantPast) }
            let recent = sorted.filter { (played["\($0.title)|\($0.artist)"] ?? .distantPast) >= cutoff }
            return recent.count >= 6 ? recent : sorted
        case .rediscover:
            return rediscover.albums
        }
    }

    private func filteredSongs(_ songs: [Track]) -> [Track] {
        switch filter {
        case .all:
            return songs
        case .lossless:
            return songs.filter { $0.isLossless }
        case .favorites:
            return songs.filter { LovedTracksService.shared.isLoved(track: $0) }
        case .recentlyAdded:
            let cutoff = Date().addingTimeInterval(-recentlyWindow)
            let sorted = songs.sorted { (meta(for: $0)?.dateAdded ?? .distantPast) > (meta(for: $1)?.dateAdded ?? .distantPast) }
            let recent = sorted.filter { (meta(for: $0)?.dateAdded ?? .distantPast) >= cutoff }
            return recent.count >= 10 ? recent : Array(sorted.prefix(40))
        case .recentlyPlayed:
            let cutoff = Date().addingTimeInterval(-recentlyWindow)
            let sorted = songs.filter { meta(for: $0)?.lastPlayed != nil }
                .sorted { (meta(for: $0)?.lastPlayed ?? .distantPast) > (meta(for: $1)?.lastPlayed ?? .distantPast) }
            let recent = sorted.filter { (meta(for: $0)?.lastPlayed ?? .distantPast) >= cutoff }
            return recent.count >= 10 ? recent : sorted
        case .rediscover:
            let keys = rediscover.keys
            return songs.filter { keys.contains("\($0.albumTitle)|\($0.artist)") }
        }
    }

    /// The alphabet scrubber only makes sense when the visible order is
    /// alphabetical; for time- or count-based sorts the first letters land in
    /// arbitrary order and the index is noise.
    var isCurrentSortAlphabetical: Bool {
        switch currentSegment {
        case .albums: albumSort == .title || albumSort == .artist
        case .songs: songSort == .title || songSort == .artist
        case .artists: artistSort == .name
        case .playlists: false
        }
    }

    func indexTitles() -> [String] {
        let items: [String]
        switch currentSegment {
        case .albums:
            items = sortedAlbums.map { albumSort == .artist ? $0.artist : $0.title }
        case .songs:
            items = sortedSongs.map { songSort == .artist ? $0.artist : $0.title }
        case .artists:
            items = sortedArtists.map(\.name)
        case .playlists:
            return []
        }
        var seen = Set<String>()
        var titles = [String]()
        for item in items {
            let letter = String(item.prefix(1)).uppercased()
            let key = letter.first?.isLetter == true ? letter : "#"
            if seen.insert(key).inserted {
                titles.append(key)
            }
        }
        return titles
    }

    func indexOfFirstItem(forLetter letter: String) -> Int? {
        let items: [(String, Int)]
        switch currentSegment {
        case .albums:
            items = sortedAlbums.enumerated().map { (albumSort == .artist ? $1.artist : $1.title, $0) }
        case .songs:
            items = sortedSongs.enumerated().map { (songSort == .artist ? $1.artist : $1.title, $0) }
        case .artists:
            items = sortedArtists.enumerated().map { ($1.name, $0) }
        case .playlists:
            return nil
        }
        for (name, index) in items {
            let first = String(name.prefix(1)).uppercased()
            let key = first.first?.isLetter == true ? first : "#"
            if key == letter { return index }
        }
        return nil
    }

    func switchSegment(to segment: Segment) {
        currentSegment = segment
        if !filter.isAvailable(in: segment) {
            filter = .all
            filter.persist()
        }
        publishSnapshot()
        loadSuggestionsIfNeeded()
        warmScrobbleCountsIfNeeded()
    }

    func albumsForArtist(_ name: String) -> [Album] {
        library.albums.filter { $0.artist == name }
    }

    func refreshPlaylists() {
        cacheLock.lock()
        cachedPlaylists = nil
        cacheLock.unlock()
        guard currentSegment == .playlists else { return }
        publishSnapshot()
    }

    /// Computes play-history-derived suggestions off-main the first time the
    /// Playlists segment is shown, then republishes so they slot in above the
    /// user's lists.
    func loadSuggestionsIfNeeded() {
        guard currentSegment == .playlists,
              cachedSuggestions == nil,
              !suggestionsLoading else { return }
        suggestionsLoading = true
        let pool = library.allTracks
        Task.detached(priority: .utility) { [weak self] in
            let suggestions = SuggestedPlaylistService.build(pool: pool)
            await MainActor.run {
                guard let self else { return }
                self.cachedSuggestions = suggestions
                self.suggestionsLoading = false
                if self.currentSegment == .playlists {
                    self.publishSnapshot()
                }
            }
        }
    }

    func search(query: String) {
        searchQuery = query
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            publishSnapshot()
        }
    }

    private static func searchFold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private var cachedSongSearchKeys: [String: String]?
    private var renderedAlbumSignatures = [String: String]()

    /// Folded "title artist album" haystacks keyed by file URL, computed once
    /// per library generation so typing in search does plain substring scans
    /// instead of locale-aware compares over every track.
    private func songSearchKeys() -> [String: String] {
        if let cached = cachedSongSearchKeys { return cached }
        var map = [String: String]()
        let tracks = library.allTracks
        map.reserveCapacity(tracks.count)
        for track in tracks {
            map[track.fileURL.path] = Self.searchFold("\(track.title)\n\(track.artist)\n\(track.albumTitle)")
        }
        cachedSongSearchKeys = map
        return map
    }

    private func buildSnapshot() -> Snapshot {
        var snapshot = Snapshot()
        let query = Self.searchFold(searchQuery)
        switch currentSegment {
        case .albums:
            let all = filteredAlbums(sortedAlbums)
            let filtered = query.isEmpty
                ? all
                : all.filter {
                    Self.searchFold($0.title).contains(query)
                        || Self.searchFold($0.artist).contains(query)
                }
            let showsRecentShelf = query.isEmpty && filter == .all && layoutMode == .grid && albumSort == .title
            let recent = showsRecentShelf ? recentlyPlayedAlbums : []
            if !recent.isEmpty {
                snapshot.appendSections([0, 1])
                snapshot.appendItems(recent.map { .recentAlbum($0) }, toSection: 0)
                snapshot.appendItems(filtered.map { .album($0) }, toSection: 1)
            } else {
                snapshot.appendSections([0])
                snapshot.appendItems(filtered.map { .album($0) })
            }
            repaint(retitledItems(albums: filtered, recent: recent), in: &snapshot)
        case .songs:
            snapshot.appendSections([0])
            var songs = filteredSongs(sortedSongs)
            if !query.isEmpty {
                let keys = songSearchKeys()
                songs = songs.filter { track in
                    if let key = keys[track.fileURL.path] { return key.contains(query) }
                    return Self.searchFold("\(track.title)\n\(track.artist)\n\(track.albumTitle)").contains(query)
                }
            }
            visibleSongs = songs
            snapshot.appendItems(songs.map { .song($0) })
        case .artists:
            snapshot.appendSections([0])
            let filtered = query.isEmpty
                ? sortedArtists
                : sortedArtists.filter { Self.searchFold($0.name).contains(query) }
            snapshot.appendItems(filtered.map { .artist($0) })
        case .playlists:
            snapshot.appendSections([0])
            var playlistItems: [LibraryItem] = []
            if query.isEmpty {
                playlistItems.append(.charts)
                playlistItems.append(.wantlist)
                playlistItems.append(contentsOf: (cachedSuggestions ?? []).map { .suggestedPlaylist($0) })
            }
            let filtered = query.isEmpty
                ? playlists
                : playlists.filter { Self.searchFold($0.name).contains(query) }
            playlistItems.append(contentsOf: filtered.map { .playlist($0) })
            snapshot.appendItems(playlistItems)
        }
        emptyState = computeEmptyState(itemCount: snapshot.numberOfItems)
        return snapshot
    }

    /// Repaints rows in place. UIKit reconfigures a cell without rebuilding it;
    /// AppKit's snapshot has no such call, so the Mac reloads the same rows.
    private func repaint(_ items: [LibraryItem], in snapshot: inout Snapshot) {
        guard !items.isEmpty else { return }
        #if canImport(UIKit)
        snapshot.reconfigureItems(items)
        #else
        snapshot.reloadItems(items)
        #endif
    }

    /// The album rows whose identity held but whose words changed — a Groq
    /// retitle during the Debut's second act, a year arriving from enrichment.
    /// The diff moves such a row rather than replacing it, which is the point,
    /// but a moved row is never re-rendered; only an explicit reconfigure
    /// repaints one.
    private func retitledItems(albums: [Album], recent: [Album]) -> [LibraryItem] {
        var next = [String: String](minimumCapacity: albums.count + recent.count)
        var changed: [LibraryItem] = []

        cacheLock.lock()
        defer { cacheLock.unlock() }

        func note(_ album: Album, as item: (Album) -> LibraryItem) {
            let key = LibraryItem.identity(of: album)
            let signature = LibraryItem.renderSignature(of: album)
            next[key] = signature
            guard let previous = renderedAlbumSignatures[key], previous != signature else { return }
            changed.append(item(album))
        }

        for album in recent { note(album, as: LibraryItem.recentAlbum) }
        for album in albums { note(album, as: LibraryItem.album) }
        renderedAlbumSignatures = next
        return changed
    }

    private func computeEmptyState(itemCount: Int) -> EmptyState {
        guard itemCount == 0 else { return .none }
        return searchQuery.isEmpty ? .noLibrary : .noSearchResults(searchQuery)
    }

    private func publishMiniPlayerState() {
        if let track = audioPlayer.currentTrack {
            miniPlayerStatePublisher.send(MiniPlayerState(track: track, isPlaying: audioPlayer.isPlaying))
        } else {
            miniPlayerStatePublisher.send(nil)
        }
    }

    @objc private func libraryDidUpdate() {
        invalidateSortCaches()
        publishSnapshot(intent: .refreshLibrary)
        prewarmSortCaches()
    }

    private func invalidateSortCaches() {
        cacheLock.lock()
        cachedSortedAlbums = nil
        cachedSortedSongs = nil
        cachedSortedArtists = nil
        cachedRecentAlbums = nil
        cachedPlaylists = nil
        cachedSuggestions = nil
        cachedMeta = nil
        cachedRediscover = nil
        cachedAlbumAdded = nil
        cachedAlbumPlayed = nil
        cachedScrobbleCounts = nil
        cachedRepresentativeTracks = [:]
        cachedFirstAlbumByArtist = nil
        cachedSongSearchKeys = nil
        cacheLock.unlock()
    }

    @objc private func trackDidChange() {
        cachedRecentAlbums = nil
        cachedRediscover = nil
        cachedAlbumPlayed = nil
        cachedMeta = nil
        if albumSort == .recentlyPlayed { cachedSortedAlbums = nil }
        if songSort == .recentlyPlayed { cachedSortedSongs = nil }
        publishMiniPlayerState()
    }

    @objc private func playbackStateDidChange() {
        publishMiniPlayerState()
    }

    @objc private func loadingStateChanged() {
        loadingPublisher.send(library.isLoading)
    }
}
