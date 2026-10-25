import AppKit
import MidgarCore
import Combine
import FlaccyCore

/// Backing model for the multi-column songs table: hydrated tracks joined
/// with date-added and local play counts, pivoted by a filter chip, narrowed by
/// the toolbar search and sorted by any column, all heavy work computed off the
/// main thread.
final class SongsTableViewModel {

    struct Row {
        var track: Track
        let dateAdded: Date
        var plays: Int
        var lastPlayed: Date?

        nonisolated var id: String { track.fileURL.absoluteString }
    }

    /// The quick pivots above the table. `mostPlayed` is the only one that
    /// carries a setting: the time range its counts are taken over.
    enum Filter: String, CaseIterable {
        case all, mostPlayed, favorites, lossless, recentlyAdded, recentlyPlayed, rediscover

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .mostPlayed: String(localized: "Most Played")
            case .favorites: String(localized: "Favorites")
            case .lossless: String(localized: "Lossless")
            case .recentlyAdded: String(localized: "Recently Added")
            case .recentlyPlayed: String(localized: "Recently Played")
            case .rediscover: String(localized: "Rediscover")
            }
        }

        var icon: String {
            switch self {
            case .all: "square.stack"
            case .mostPlayed: "chart.bar.fill"
            case .favorites: "heart.fill"
            case .lossless: "waveform.badge.magnifyingglass"
            case .recentlyAdded: "clock.badge.plus"
            case .recentlyPlayed: "clock.arrow.circlepath"
            case .rediscover: "sparkle.magnifyingglass"
            }
        }

        /// The ordering a freshly chosen chip starts from, nil when the chip
        /// should leave whatever the person last sorted by alone.
        var naturalSort: [SortTier]? {
            switch self {
            case .all, .favorites, .lossless: nil
            case .mostPlayed: [SortTier(column: .plays, ascending: false), SortTier(column: .lastPlayed, ascending: false)]
            case .recentlyAdded: [SortTier(column: .dateAdded, ascending: false)]
            case .recentlyPlayed: [SortTier(column: .lastPlayed, ascending: false)]
            case .rediscover: [SortTier(column: .plays, ascending: false)]
            }
        }
    }

    struct SortTier: Codable, Equatable {
        let column: Column
        let ascending: Bool
    }

    enum Column: String, CaseIterable, Codable {
        case title, artist, album, trackNumber, duration, codec, quality, plays, lastPlayed, loved, dateAdded

        var headerTitle: String {
            switch self {
            case .title: String(localized: "Title")
            case .artist: String(localized: "Artist")
            case .album: String(localized: "Album")
            case .trackNumber: "#"
            case .duration: String(localized: "Time")
            case .codec: String(localized: "Codec")
            case .quality: String(localized: "Quality")
            case .plays: String(localized: "Plays")
            case .lastPlayed: String(localized: "Last Played")
            case .loved: String(localized: "Loved")
            case .dateAdded: String(localized: "Date Added")
            }
        }

        var initialWidth: CGFloat {
            switch self {
            case .title: 260
            case .artist: 160
            case .album: 180
            case .trackNumber: 40
            case .duration: 52
            case .codec: 58
            case .quality: 80
            case .plays: 50
            case .lastPlayed: 120
            case .loved: 44
            case .dateAdded: 120
            }
        }
    }

    let rowsPublisher = CurrentValueSubject<[Row], Never>([])

    private(set) var sortTiers: [SortTier]
    private var allRows: [Row] = []
    private var searchQuery = LibrarySearchState.query
    private var loadGeneration = 0
    private var publishGeneration = 0
    private var loadTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var trackUpdateTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    private let derived = SongsDerivedData()

    #if DEBUG
    private(set) var debugReloadCount = 0
    private(set) var debugTrackUpdateCount = 0

    var debugCurrentTrackIsIndexed: Bool {
        guard let track = AudioPlayer.shared.currentTrack else { return false }
        return (try? DatabaseManager.shared.fetchTrack(byRelativePath: relativePath(for: track.fileURL))) != nil
    }
    #endif

    private(set) var filter: Filter
    private(set) var mostPlayedRange: ChartPeriod
    private(set) var displayedPlaysRange: ChartPeriod?

    private static let maxTiers = 3
    private static let sortTiersKey = "flaccy.mac.songsSortTiers"
    private static let sortColumnKey = "flaccy.mac.songsSortColumn"
    private static let sortAscendingKey = "flaccy.mac.songsSortAscending"
    private static let filterKey = "flaccy.mac.songsFilter"
    private static let rangeKey = "flaccy.mac.songsMostPlayedRange"

    init() {
        sortTiers = Self.loadTiers()
        filter = Filter(rawValue: UserDefaults.standard.string(forKey: Self.filterKey) ?? "") ?? .all
        mostPlayedRange = ChartPeriod(rawValue: UserDefaults.standard.string(forKey: Self.rangeKey) ?? "") ?? .month

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: Library.didUpdateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(lovedDidChange(_:)), name: LovedTracksService.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(trackChanged), name: AudioPlayer.trackDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(searchChanged(_:)), name: .flaccySearchQueryChanged, object: nil
        )
        reload()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var visibleTracks: [Track] {
        rowsPublisher.value.map(\.track)
    }

    var hasLibrary: Bool { !allRows.isEmpty }

    var chips: [FilterChip] {
        Filter.allCases.map { chip in
            FilterChip(
                id: chip.rawValue,
                title: chip == .mostPlayed ? mostPlayedTitle : chip.title,
                icon: chip.icon,
                hasMenu: chip == .mostPlayed
            )
        }
    }

    var mostPlayedTitle: String {
        String(localized: "Most Played · \(mostPlayedRange.shortName)")
    }

    var playsColumnTitle: String {
        displayedPlaysRange.map { String(localized: "Plays · \($0.shortName)") } ?? Column.plays.headerTitle
    }

    func select(_ newFilter: Filter) {
        filter = newFilter
        UserDefaults.standard.set(newFilter.rawValue, forKey: Self.filterKey)
        if let natural = newFilter.naturalSort {
            storeSortTiers(natural)
        }
        MidgarLog.info("Songs filter: \(newFilter.rawValue)", category: .ui)
        publish()
    }

    func selectMostPlayed(range: ChartPeriod) {
        mostPlayedRange = range
        UserDefaults.standard.set(range.rawValue, forKey: Self.rangeKey)
        select(.mostPlayed)
    }

    /// Folds a freshly clicked column into the tier stack: same column toggles
    /// its own direction and stays primary; a new column becomes primary with
    /// the prior tiers demoted to secondaries (capped), so "sort by Artist then
    /// by Plays" keeps Artist as the stable secondary key.
    func applyPrimarySort(column: Column, ascending: Bool) {
        var tiers = sortTiers.filter { $0.column != column }
        tiers.insert(SortTier(column: column, ascending: ascending), at: 0)
        if tiers.count > Self.maxTiers { tiers = Array(tiers.prefix(Self.maxTiers)) }
        setSortTiers(tiers)
    }

    func setSortTiers(_ tiers: [SortTier]) {
        storeSortTiers(tiers)
        publish()
    }

    private func storeSortTiers(_ tiers: [SortTier]) {
        sortTiers = tiers.isEmpty ? [SortTier(column: .title, ascending: true)] : tiers
        if let data = try? JSONEncoder().encode(sortTiers) {
            UserDefaults.standard.set(data, forKey: Self.sortTiersKey)
        }
    }

    private static func loadTiers() -> [SortTier] {
        if let data = UserDefaults.standard.data(forKey: sortTiersKey),
           let decoded = try? JSONDecoder().decode([SortTier].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        let column = Column(rawValue: UserDefaults.standard.string(forKey: sortColumnKey) ?? "") ?? .title
        let ascending = UserDefaults.standard.object(forKey: sortAscendingKey) as? Bool ?? true
        return [SortTier(column: column, ascending: ascending)]
    }

    @objc private func reload() {
        #if DEBUG
        debugReloadCount += 1
        #endif
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        let derived = self.derived
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let records = (try? DatabaseManager.shared.fetchAllTracks()) ?? []
            guard !Task.isCancelled else { return }
            let counts = derived.scrobbleCounts(for: .allTime)
            let rows = records.map { record in
                Row(
                    track: Track.from(record: record, artwork: nil),
                    dateAdded: record.dateAdded,
                    plays: counts[LastFMStatsService.trackKey(record.title, record.artist)] ?? 0,
                    lastPlayed: record.lastPlayed
                )
            }
            await MainActor.run { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.allRows = rows
                self.publish()
            }
        }
    }

    @objc private func trackChanged() {
        guard let track = AudioPlayer.shared.currentTrack else { return }
        let path = track.fileURL.absoluteString
        let relativePath = relativePath(for: track.fileURL)
        trackUpdateTask?.cancel()
        trackUpdateTask = Task.detached(priority: .utility) {
            let record = try? DatabaseManager.shared.fetchTrack(byRelativePath: relativePath)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.applyTrackUpdate(path: path, record: record)
            }
        }
    }

    private func applyTrackUpdate(path: String, record: TrackRecord?) {
        guard let record else { return }
        #if DEBUG
        debugTrackUpdateCount += 1
        #endif
        let counts = derived.scrobbleCounts(for: .allTime)
        let plays = counts[LastFMStatsService.trackKey(record.title, record.artist)] ?? record.playCount
        if let index = allRows.firstIndex(where: { $0.id == path }) {
            allRows[index].plays = plays
            allRows[index].lastPlayed = record.lastPlayed
        }
        let needsReorder = filter == .mostPlayed || filter == .recentlyPlayed || filter == .rediscover
            || sortTiers.contains { $0.column == .plays || $0.column == .lastPlayed }
        guard !needsReorder else {
            publish()
            return
        }
        var rows = rowsPublisher.value
        guard let index = rows.firstIndex(where: { $0.id == path }) else { return }
        rows[index].plays = plays
        rows[index].lastPlayed = record.lastPlayed
        rowsPublisher.send(rows)
    }

    private func relativePath(for url: URL) -> String {
        if let song = RemoteTrackPath(assetURL: url) { return song.path }
        let root = LibraryPaths.root.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return url.lastPathComponent }
        let relative = String(path.dropFirst(root.count))
        return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
    }

    @objc private func lovedDidChange(_ notification: Notification) {
        for index in allRows.indices {
            allRows[index].track.loved = LovedTracksService.shared.isLoved(track: allRows[index].track)
        }
        publish()
    }

    @objc private func searchChanged(_ notification: Notification) {
        searchQuery = notification.userInfo?[LibraryNavigator.Key.query] as? String ?? ""
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }

    /// Filtering and localized sorting of the full library happen off the
    /// main actor; each new pass cancels the previous one, and a generation
    /// token drops results that raced a newer request.
    private func publish() {
        publishGeneration += 1
        let generation = publishGeneration
        let rows = allRows
        let query = searchQuery
        let tiers = sortTiers
        let filter = self.filter
        let range = mostPlayedRange
        let derived = self.derived
        publishTask?.cancel()
        publishTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let pivot = Self.pivoted(rows, by: filter, range: range, derived: derived, now: Date())
            guard !Task.isCancelled else { return }
            let result = Self.sorted(Self.filtered(pivot, query: query), tiers: tiers)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.publishGeneration == generation else { return }
                self.displayedPlaysRange = filter == .mostPlayed ? range : nil
                self.rowsPublisher.send(result)
            }
        }
    }

    /// The chip's own membership, decided over the whole library before the
    /// search narrows it, so "recent" keeps its meaning however little the
    /// query matches. Most Played swaps each row's play count for the count
    /// inside the range, which is also what the Plays column then shows.
    nonisolated private static func pivoted(
        _ rows: [Row], by filter: Filter, range: ChartPeriod, derived: SongsDerivedData, now: Date
    ) -> [Row] {
        switch filter {
        case .all:
            return rows
        case .favorites:
            return rows.filter { $0.track.loved }
        case .lossless:
            return rows.filter { $0.track.isLossless }
        case .recentlyAdded:
            let ids = LibraryFilterRules.recentlyAdded(
                rows.map { (id: $0.id, dateAdded: $0.dateAdded) }, now: now, thresholds: .songs
            )
            return members(of: rows, ids: ids)
        case .recentlyPlayed:
            let ids = LibraryFilterRules.recentlyPlayed(
                rows.map { (id: $0.id, lastPlayed: $0.lastPlayed) }, now: now, thresholds: .songs
            )
            return members(of: rows, ids: ids)
        case .rediscover:
            let albums = Set(derived.rediscoverAlbumKeys(now: now))
            return rows.filter { albums.contains("\($0.track.albumTitle)|\($0.track.artist)") }
        case .mostPlayed:
            let counts = derived.scrobbleCounts(for: range)
            let ranged = rows.map { row -> Row in
                var copy = row
                copy.plays = counts[LastFMStatsService.trackKey(row.track.title, row.track.artist)] ?? 0
                return copy
            }
            let ids = LibraryFilterRules.mostPlayed(
                ranged.map { (id: $0.id, plays: $0.plays, lastPlayed: $0.lastPlayed, title: $0.track.title) }
            )
            return members(of: ranged, ids: ids)
        }
    }

    nonisolated private static func members(of rows: [Row], ids: [String]) -> [Row] {
        let wanted = Set(ids)
        return rows.filter { wanted.contains($0.id) }
    }

    nonisolated private static func filtered(_ rows: [Row], query rawQuery: String) -> [Row] {
        let query = fold(rawQuery)
        guard !query.isEmpty else { return rows }
        return rows.filter {
            fold("\($0.track.title)\n\($0.track.artist)\n\($0.track.albumTitle)").contains(query)
        }
    }

    nonisolated private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Stable multi-tier sort: rows are compared tier by tier, the first
    /// non-equal tier decides, and equal rows fall back to title then file path
    /// so the order is deterministic across reloads.
    nonisolated private static func sorted(_ rows: [Row], tiers rawTiers: [SortTier]) -> [Row] {
        let tiers = rawTiers.isEmpty ? [SortTier(column: .title, ascending: true)] : rawTiers
        return rows.sorted { lhs, rhs in
            for tier in tiers {
                let result = compare(lhs, rhs, by: tier.column)
                if result != .orderedSame {
                    return tier.ascending ? result == .orderedAscending : result == .orderedDescending
                }
            }
            let byTitle = lhs.track.title.localizedCaseInsensitiveCompare(rhs.track.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return lhs.track.fileURL.absoluteString < rhs.track.fileURL.absoluteString
        }
    }

    nonisolated private static func compare(_ lhs: Row, _ rhs: Row, by column: Column) -> ComparisonResult {
        switch column {
        case .title: lhs.track.title.localizedCaseInsensitiveCompare(rhs.track.title)
        case .artist: lhs.track.artist.localizedCaseInsensitiveCompare(rhs.track.artist)
        case .album: lhs.track.albumTitle.localizedCaseInsensitiveCompare(rhs.track.albumTitle)
        case .codec: (lhs.track.codec ?? "").localizedCaseInsensitiveCompare(rhs.track.codec ?? "")
        case .trackNumber: order(lhs.track.trackNumber, rhs.track.trackNumber)
        case .duration: order(lhs.track.duration, rhs.track.duration)
        case .quality: order(qualityRank(lhs.track), qualityRank(rhs.track))
        case .plays: order(lhs.plays, rhs.plays)
        case .lastPlayed: order(lhs.lastPlayed ?? .distantPast, rhs.lastPlayed ?? .distantPast)
        case .loved: order(lhs.track.loved ? 1 : 0, rhs.track.loved ? 1 : 0)
        case .dateAdded: order(lhs.dateAdded, rhs.dateAdded)
        }
    }

    nonisolated private static func order<V: Comparable>(_ lhs: V, _ rhs: V) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
    }

    nonisolated private static func qualityRank(_ track: Track) -> Int {
        (track.isLossless ? 1 << 24 : 0) + (track.bitDepth ?? 0) * 100_000 + (track.sampleRate ?? 0)
    }
}
