import AppKit
import Combine

/// Backing model for the multi-column songs table: hydrated tracks joined
/// with date-added and local play counts, filtered by the toolbar search and
/// sorted by any column, all heavy work computed off the main thread.
final class SongsTableViewModel {

    struct Row {
        var track: Track
        let dateAdded: Date
        var plays: Int
        let lastPlayed: Date?
    }

    struct SortTier: Codable, Equatable {
        let column: Column
        let ascending: Bool
    }

    enum Column: String, CaseIterable, Codable {
        case title, artist, album, trackNumber, duration, codec, quality, plays, lastPlayed, loved, dateAdded

        var headerTitle: String {
            switch self {
            case .title: "Title"
            case .artist: "Artist"
            case .album: "Album"
            case .trackNumber: "#"
            case .duration: "Time"
            case .codec: "Codec"
            case .quality: "Quality"
            case .plays: "Plays"
            case .lastPlayed: "Last Played"
            case .loved: "Loved"
            case .dateAdded: "Date Added"
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

    private static let maxTiers = 3
    private static let sortTiersKey = "flaccy.mac.songsSortTiers"
    private static let sortColumnKey = "flaccy.mac.songsSortColumn"
    private static let sortAscendingKey = "flaccy.mac.songsSortAscending"

    init() {
        sortTiers = Self.loadTiers()

        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: Library.didUpdateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(lovedDidChange(_:)), name: LovedTracksService.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: AudioPlayer.trackDidChange, object: nil
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
        sortTiers = tiers.isEmpty ? [SortTier(column: .title, ascending: true)] : tiers
        if let data = try? JSONEncoder().encode(sortTiers) {
            UserDefaults.standard.set(data, forKey: Self.sortTiersKey)
        }
        publish()
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
        loadGeneration += 1
        let generation = loadGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            let records = (try? DatabaseManager.shared.fetchAllTracks()) ?? []
            let counts = LastFMStatsService.shared.scrobbleCounts(period: .allTime)
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

    @objc private func lovedDidChange(_ notification: Notification) {
        for index in allRows.indices {
            allRows[index].track.loved = LovedTracksService.shared.isLoved(track: allRows[index].track)
        }
        publish()
    }

    @objc private func searchChanged(_ notification: Notification) {
        searchQuery = notification.userInfo?[LibraryNavigator.Key.query] as? String ?? ""
        publish()
    }

    /// Filtering and localized sorting of the full library happen off the
    /// main actor (they run on every track change, love toggle, and search
    /// keystroke); a generation token drops stale results.
    private func publish() {
        publishGeneration += 1
        let generation = publishGeneration
        let rows = allRows
        let query = searchQuery
        let tiers = sortTiers
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.sorted(Self.filtered(rows, query: query), tiers: tiers)
            await MainActor.run { [weak self] in
                guard let self, self.publishGeneration == generation else { return }
                self.rowsPublisher.send(result)
            }
        }
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
            return lhs.track.fileURL.path < rhs.track.fileURL.path
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
