import Combine
import UIKit

nonisolated enum LibraryItem: Hashable, Sendable {
    case album(Album)
    case recentAlbum(Album)
    case song(Track)
    case artist(ArtistItem)
    case playlist(PlaylistItem)
    case suggestedPlaylist(SuggestedPlaylist)
    case charts
    case wantlist
}

nonisolated struct ArtistItem: Hashable, Sendable {
    let name: String
    let albumCount: Int
    let artwork: UIImage?

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
            case .title: "Title"
            case .artist: "Artist"
            case .year: "Year"
            case .recentlyAdded: "Recently Added"
            case .recentlyPlayed: "Recently Played"
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
            case .title: "Title"
            case .artist: "Artist"
            case .mostScrobbled: "Most Played"
            case .recentlyPlayed: "Recently Played"
            case .dateAdded: "Date Added"
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
        case name, albumCount

        var displayName: String {
            switch self {
            case .name: "Name"
            case .albumCount: "Album Count"
            }
        }

        var icon: String {
            switch self {
            case .name: "textformat.abc"
            case .albumCount: "number"
            }
        }
    }

    typealias Snapshot = NSDiffableDataSourceSnapshot<Int, LibraryItem>

    private let library: LibraryProviding
    private let audioPlayer: AudioPlaying

    let snapshotPublisher = PassthroughSubject<Snapshot, Never>()
    let miniPlayerStatePublisher = PassthroughSubject<MiniPlayerState?, Never>()
    let loadingPublisher = PassthroughSubject<Bool, Never>()

    struct MiniPlayerState {
        let track: Track
        let isPlaying: Bool
    }

    private(set) var currentSegment: Segment = .albums
    private var searchQuery: String = ""
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
        if let cached = cachedMeta { return cached }
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
        cachedMeta = map
        return map
    }

    private static let documentsPath = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL.path

    private func relativePath(for url: URL) -> String {
        let docs = Self.documentsPath
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(docs) else { return url.lastPathComponent }
        let relative = String(path.dropFirst(docs.count))
        return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
    }

    /// Returns the codec-populated variant of a lightweight library track so its
    /// `qualityBadge`/`isLossless` resolve; falls back to the original if unknown.
    private func hydrate(_ track: Track) -> Track {
        trackMeta[relativePath(for: track.fileURL)]?.track ?? track
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
                    self.snapshotPublisher.send(self.buildSnapshot())
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
        if let cached = cachedRepresentativeTracks[key] { return cached }
        let best = album.tracks.map { hydrate($0) }.max { qualityRank($0) < qualityRank($1) }
        if let best { cachedRepresentativeTracks[key] = best }
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
        album.tracks.contains { LovedTracksService.shared.isLoved(track: $0) }
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
        if let cached = cachedSortedAlbums { return cached }
        let result: [Album]
        switch albumSort {
        case .title:
            result = library.albums.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            result = library.albums.sorted {
                let cmp = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                return cmp == .orderedSame ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending : cmp == .orderedAscending
            }
        case .year:
            result = library.albums.sorted {
                let y0 = $0.year ?? "9999"
                let y1 = $1.year ?? "9999"
                return y0 == y1 ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending : y0 < y1
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
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            result = hasPlay + noPlay
        }
        cachedSortedAlbums = result
        return result
    }

    var sortedSongs: [Track] {
        if let cached = cachedSortedSongs { return cached }
        let tracks = library.allTracks
        guard !tracks.isEmpty else { return tracks }
        let result: [Track]
        switch songSort {
        case .title:
            result = tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            result = tracks.sorted {
                let cmp = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                return cmp == .orderedSame ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending : cmp == .orderedAscending
            }
        case .mostScrobbled:
            guard let counts = cachedScrobbleCounts.flatMap({ $0.period == scrobbleRange ? $0.counts : nil }) else {
                warmScrobbleCountsIfNeeded()
                return tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            }
            let scored = tracks.filter { counts[LastFMStatsService.trackKey($0.title, $0.artist)] ?? 0 > 0 }
                .sorted {
                    let a = counts[LastFMStatsService.trackKey($0.title, $0.artist)] ?? 0
                    let b = counts[LastFMStatsService.trackKey($1.title, $1.artist)] ?? 0
                    return a == b ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending : a > b
                }
            let unscrobbled = tracks.filter { counts[LastFMStatsService.trackKey($0.title, $0.artist)] ?? 0 == 0 }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            result = scored + unscrobbled
        case .recentlyPlayed:
            let sortKeys: [(fileURL: String, lastPlayed: Date?)]
            do {
                sortKeys = try DatabaseManager.shared.fetchTrackSortKeys()
            } catch {
                result = tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                cachedSortedSongs = result
                return result
            }
            let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
            var lastPlayedByURL = [URL: Date]()
            for key in sortKeys {
                if let date = key.lastPlayed {
                    lastPlayedByURL[docsDir.appendingPathComponent(key.fileURL)] = date
                }
            }
            let played = tracks.filter { lastPlayedByURL[$0.fileURL] != nil }
                .sorted { (lastPlayedByURL[$0.fileURL] ?? .distantPast) > (lastPlayedByURL[$1.fileURL] ?? .distantPast) }
            let unplayed = tracks.filter { lastPlayedByURL[$0.fileURL] == nil }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            result = played + unplayed
        case .dateAdded:
            result = tracks.sorted {
                (meta(for: $0)?.dateAdded ?? .distantPast) > (meta(for: $1)?.dateAdded ?? .distantPast)
            }
        }
        cachedSortedSongs = result.map { hydrate($0) }
        return cachedSortedSongs ?? result
    }

    var sortedArtists: [ArtistItem] {
        if let cached = cachedSortedArtists { return cached }
        let result: [ArtistItem]
        switch artistSort {
        case .name:
            result = artists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .albumCount:
            result = artists.sorted { $0.albumCount > $1.albumCount }
        }
        cachedSortedArtists = result
        return result
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

    var artists: [ArtistItem] {
        var seen = [String: ArtistItem]()
        for album in library.albums {
            if let existing = seen[album.artist] {
                seen[album.artist] = ArtistItem(
                    name: album.artist,
                    albumCount: existing.albumCount + 1,
                    artwork: existing.artwork ?? album.artwork
                )
            } else {
                seen[album.artist] = ArtistItem(
                    name: album.artist,
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
            self, selector: #selector(playbackDidChange), name: AudioPlayer.trackDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackDidChange), name: AudioPlayer.playbackStateDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(loadingStateChanged), name: Library.loadingStateChanged, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func loadLibrary() async {
        await library.reload()
    }

    func restorePlaybackState() {
        audioPlayer.restoreQueueState()
    }

    func importFiles(from urls: [URL]) async {
        await library.importFiles(from: urls)
    }

    func setAlbumSort(_ sort: AlbumSort) {
        albumSort = sort
        cachedSortedAlbums = nil
        UserDefaults.standard.set(sort.rawValue, forKey: "albumSort")
        snapshotPublisher.send(buildSnapshot())
    }

    func setSongSort(_ sort: SongSort) {
        songSort = sort
        cachedSortedSongs = nil
        UserDefaults.standard.set(sort.rawValue, forKey: "songSort")
        warmScrobbleCountsIfNeeded()
        snapshotPublisher.send(buildSnapshot())
    }

    func setScrobbleRange(_ range: ChartPeriod) {
        guard scrobbleRange != range else { return }
        scrobbleRange = range
        cachedScrobbleCounts = nil
        if songSort == .mostScrobbled { cachedSortedSongs = nil }
        UserDefaults.standard.set(range.rawValue, forKey: "songScrobbleRange")
        warmScrobbleCountsIfNeeded()
        snapshotPublisher.send(buildSnapshot())
    }

    func setArtistSort(_ sort: ArtistSort) {
        artistSort = sort
        cachedSortedArtists = nil
        UserDefaults.standard.set(sort.rawValue, forKey: "artistSort")
        snapshotPublisher.send(buildSnapshot())
    }

    func cycleLayoutMode() {
        layoutMode = layoutMode.next
        layoutMode.persist()
    }

    func setFilter(_ filter: LibraryFilter) {
        guard self.filter != filter else { return }
        self.filter = filter
        filter.persist()
        snapshotPublisher.send(buildSnapshot())
    }

    /// Rebuilds and republishes the current snapshot without changing state,
    /// e.g. after loved state changes while the Favorites pivot is active.
    func refilter() {
        snapshotPublisher.send(buildSnapshot())
    }

    func currentSnapshot() -> Snapshot {
        buildSnapshot()
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
        snapshotPublisher.send(buildSnapshot())
        loadSuggestionsIfNeeded()
        warmScrobbleCountsIfNeeded()
    }

    func albumsForArtist(_ name: String) -> [Album] {
        library.albums.filter { $0.artist == name }
    }

    func refreshPlaylists() {
        cachedPlaylists = nil
        guard currentSegment == .playlists else { return }
        snapshotPublisher.send(buildSnapshot())
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
                    self.snapshotPublisher.send(self.buildSnapshot())
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
            snapshotPublisher.send(buildSnapshot())
        }
    }

    private static func searchFold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private var cachedSongSearchKeys: [String: String]?

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
            let showsRecentShelf = query.isEmpty && filter == .all && layoutMode == .grid
            let recent = showsRecentShelf ? recentlyPlayedAlbums : []
            if !recent.isEmpty {
                snapshot.appendSections([0, 1])
                snapshot.appendItems(recent.map { .recentAlbum($0) }, toSection: 0)
                snapshot.appendItems(filtered.map { .album($0) }, toSection: 1)
            } else {
                snapshot.appendSections([0])
                snapshot.appendItems(filtered.map { .album($0) })
            }
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
        snapshotPublisher.send(buildSnapshot())
    }

    private func invalidateSortCaches() {
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
    }

    @objc private func playbackDidChange() {
        cachedRecentAlbums = nil
        cachedRediscover = nil
        cachedAlbumPlayed = nil
        cachedMeta = nil
        if albumSort == .recentlyPlayed { cachedSortedAlbums = nil }
        if songSort == .recentlyPlayed { cachedSortedSongs = nil }
        publishMiniPlayerState()
    }

    @objc private func loadingStateChanged() {
        loadingPublisher.send(library.isLoading)
    }
}
