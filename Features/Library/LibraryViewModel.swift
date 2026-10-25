import Combine
import MidgarCore
import FlaccyCore

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

final class LibraryViewModel {

    /// Guards sort/meta caches shared by the background snapshot queue and main.
    let cacheLock = NSRecursiveLock()

    let library: LibraryProviding
    let audioPlayer: AudioPlaying

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
    var debutAct: LibraryDebutAct = .indexing

    /// True while the Debut still has something to show but the library has
    /// become browsable, so the showpiece belongs in a sheet the reader opens
    /// rather than across the screen they are already using.
    var debutIsPending: Bool { surfaceRouter.debutIsPending }

    nonisolated enum LibrarySignal: Sendable {
        case load(LibraryLoadProgress, Double)
        case job(EnrichmentJobProgress)
        case tick
    }

    var surfaceCancellable: AnyCancellable?
    var surfaceRouter = LibrarySurfaceRouter()
    var debutDirector = LibraryDebutDirector()
    var latestLoad: LibraryLoadProgress = .idle
    var latestFraction: Double = 0
    var latestJob: EnrichmentJobProgress = .idle
    var finishingStartedAt: Date?
    var heardFromJob = false
    let debutTick = PassthroughSubject<Void, Never>()
    var debutTicker: Task<Void, Never>?
    lazy var debutCompleted: Bool = Self.readDebutCompleted()

    private(set) var currentSegment: Segment = .albums
    var searchQuery: String = ""
    var isSearching: Bool { !searchQuery.isEmpty }
    private(set) var albumSort: AlbumSort = AlbumSort(rawValue: UserDefaults.standard.string(forKey: "albumSort") ?? "") ?? .title
    private(set) var songSort: SongSort = SongSort(rawValue: UserDefaults.standard.string(forKey: "songSort") ?? "") ?? .title
    private(set) var scrobbleRange: ChartPeriod = ChartPeriod(rawValue: UserDefaults.standard.string(forKey: "songScrobbleRange") ?? "") ?? .allTime
    private(set) var artistSort: ArtistSort = ArtistSort(rawValue: UserDefaults.standard.string(forKey: "artistSort") ?? "") ?? .name
    private(set) var layoutMode: LibraryLayoutMode = .persisted
    private(set) var filter: LibraryFilter = .persisted

    struct TrackMeta {
        let track: Track
        let dateAdded: Date
        let lastPlayed: Date?
    }

    static let sharedMetaLock = NSLock()
    static var sharedMeta: [ObjectIdentifier: [String: TrackMeta]] = [:]
    static var sharedMetaGeneration = 0

    #if DEBUG
    private(set) static var debugMetaBuildCount = 0

    static func debugResetMetaBuildCount() {
        sharedMetaLock.lock()
        debugMetaBuildCount = 0
        sharedMetaLock.unlock()
    }

    static func debugInvalidateSharedMeta() { invalidateSharedMeta() }

    func debugTrackMetaCount() -> Int { trackMeta.count }
    #endif

    var cachedScrobbleCounts: (period: ChartPeriod, counts: [String: Int])?
    var scrobbleCountsWarming = false
    var cachedRediscover: (keys: Set<String>, albums: [Album])?
    let recentlyWindow: TimeInterval = 60 * 60 * 24 * 30
    let rediscoverMinDays = 14
    let rediscoverMinPlays = 2

    var trackMeta: [String: TrackMeta] {
        let key = ObjectIdentifier(library)
        Self.sharedMetaLock.lock()
        if let cached = Self.sharedMeta[key] {
            Self.sharedMetaLock.unlock()
            return cached
        }
        let generation = Self.sharedMetaGeneration
        Self.sharedMetaLock.unlock()

        #if DEBUG
        Self.sharedMetaLock.lock()
        Self.debugMetaBuildCount += 1
        Self.sharedMetaLock.unlock()
        #endif

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

        Self.sharedMetaLock.lock()
        if generation == Self.sharedMetaGeneration {
            Self.sharedMeta[key] = map
        }
        let result = Self.sharedMeta[key] ?? map
        Self.sharedMetaLock.unlock()
        return result
    }

    static func invalidateSharedMeta() {
        sharedMetaLock.lock()
        sharedMeta.removeAll()
        sharedMetaGeneration &+= 1
        sharedMetaLock.unlock()
    }

    static func removeSharedMeta(for library: LibraryProviding) {
        sharedMetaLock.lock()
        sharedMeta.removeValue(forKey: ObjectIdentifier(library))
        sharedMetaLock.unlock()
    }

    #if os(macOS)
    static var documentsPath: String { LibraryPaths.root.path }
    #else
    static let documentsPath = LibraryPaths.root.path
    #endif

    func relativePath(for url: URL) -> String {
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
    func hydrate(_ track: Track) -> Track {
        if track.codec != nil { return track }
        return trackMeta[relativePath(for: track.fileURL)]?.track ?? track
    }

    /// Faster than `localizedCaseInsensitiveCompare` across thousands of rows;
    /// library lists are not locale-sensitive catalogue sorts.
    static func titleOrder(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedAscending
    }

    func meta(for track: Track) -> TrackMeta? {
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

    var cachedRepresentativeTracks = [String: Track]()
    var cachedFirstAlbumByArtist: [String: Album]?

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
    ///
    /// Indexes performances as well as credits: a composer on a Various Artists
    /// soundtrack is credited with no album, and an index of credits alone
    /// would leave every such cell blank.
    func firstAlbum(forArtist name: String) -> Album? {
        if cachedFirstAlbumByArtist == nil {
            var index = [String: Album]()
            for album in library.albums {
                var keys = [artistMatchKey(album.artist)]
                keys += album.tracks.map { artistMatchKey($0.artist) }
                for key in keys where index[key] == nil { index[key] = album }
            }
            cachedFirstAlbumByArtist = index
        }
        return cachedFirstAlbumByArtist?[artistMatchKey(name)]
    }

    var cachedAlbumAdded: [String: Date]?
    var cachedAlbumPlayed: [String: Date]?

    var cachedSortedAlbums: [Album]?
    var cachedSortedSongs: [Track]?
    var cachedSortedArtists: [ArtistItem]?
    var cachedRecentAlbums: [Album]?
    var cachedPlaylists: [PlaylistItem]?
    var cachedSuggestions: [SuggestedPlaylist]?
    var suggestionsLoading = false
    var searchDebounceTask: Task<Void, Never>?

    enum EmptyState {
        case none
        case noLibrary
        case noSearchResults(String)
    }

    var emptyState: EmptyState = .none
    var visibleSongs: [Track] = []
    var duplicateCopies: [URL: [Track]] = [:]

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

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        Self.removeSharedMeta(for: library)
    }

    func loadLibrary() async {
        await library.reload()
    }

    func restorePlaybackState() {
        audioPlayer.restoreQueueState()
    }

    @discardableResult
    func importFiles(
        from urls: [URL],
        progress: @escaping @MainActor @Sendable (LibraryImportProgress) -> Void,
        decideReplacements: @escaping ImportReplacementDecider
    ) async -> LibraryImportOutcome {
        await library.importFiles(from: urls, progress: progress, decideReplacements: decideReplacements)
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

    var snapshotEpoch = 0

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
    var cachedSongSearchKeys: [String: String]?
    var renderedAlbumSignatures = [String: String]()

    /// Builds the next snapshot on the next turn of the main actor, after the
    /// segmented control / menu animation that asked for it has started. A
    /// request that a newer one has superseded by then is dropped unbuilt.
    func publishSnapshot(intent: SnapshotIntent = .replaceList) {
        snapshotEpoch &+= 1
        let epoch = snapshotEpoch
        snapshotIntent = intent
        Task { @MainActor [weak self] in
            guard let self, epoch == self.snapshotEpoch else { return }
            self.snapshotPublisher.send(self.buildSnapshot())
        }
    }

    func availableFilters() -> [LibraryFilter] {
        LibraryFilter.allCases.filter { $0.isAvailable(in: currentSegment) }
    }

    var rediscoverAlbums: [Album] {
        rediscover.albums
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

}
