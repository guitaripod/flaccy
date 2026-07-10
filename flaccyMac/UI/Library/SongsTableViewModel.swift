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
    }

    enum Column: String, CaseIterable {
        case title, artist, album, duration, codec, quality, plays, loved, dateAdded

        var headerTitle: String {
            switch self {
            case .title: "Title"
            case .artist: "Artist"
            case .album: "Album"
            case .duration: "Time"
            case .codec: "Codec"
            case .quality: "Quality"
            case .plays: "Plays"
            case .loved: "Loved"
            case .dateAdded: "Date Added"
            }
        }

        var initialWidth: CGFloat {
            switch self {
            case .title: 260
            case .artist: 160
            case .album: 180
            case .duration: 52
            case .codec: 58
            case .quality: 80
            case .plays: 50
            case .loved: 44
            case .dateAdded: 120
            }
        }
    }

    let rowsPublisher = CurrentValueSubject<[Row], Never>([])

    private(set) var sortColumn: Column
    private(set) var sortAscending: Bool
    private var allRows: [Row] = []
    private var searchQuery = LibrarySearchState.query
    private var loadGeneration = 0

    private static let sortColumnKey = "flaccy.mac.songsSortColumn"
    private static let sortAscendingKey = "flaccy.mac.songsSortAscending"

    init() {
        sortColumn = Column(rawValue: UserDefaults.standard.string(forKey: Self.sortColumnKey) ?? "") ?? .title
        sortAscending = UserDefaults.standard.object(forKey: Self.sortAscendingKey) as? Bool ?? true

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

    func setSort(column: Column, ascending: Bool) {
        sortColumn = column
        sortAscending = ascending
        UserDefaults.standard.set(column.rawValue, forKey: Self.sortColumnKey)
        UserDefaults.standard.set(ascending, forKey: Self.sortAscendingKey)
        publish()
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
                    plays: counts[LastFMStatsService.trackKey(record.title, record.artist)] ?? 0
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

    private func publish() {
        rowsPublisher.send(sorted(filtered(allRows)))
    }

    private func filtered(_ rows: [Row]) -> [Row] {
        let query = fold(searchQuery)
        guard !query.isEmpty else { return rows }
        return rows.filter {
            fold("\($0.track.title)\n\($0.track.artist)\n\($0.track.albumTitle)").contains(query)
        }
    }

    private func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func sorted(_ rows: [Row]) -> [Row] {
        let ascending = sortAscending
        func compareTitles(_ a: Row, _ b: Row) -> Bool {
            a.track.title.localizedCaseInsensitiveCompare(b.track.title) == .orderedAscending
        }
        func byString(_ key: (Row) -> String) -> [Row] {
            rows.sorted {
                let cmp = key($0).localizedCaseInsensitiveCompare(key($1))
                if cmp == .orderedSame { return compareTitles($0, $1) }
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        }
        func byValue<V: Comparable>(_ key: (Row) -> V) -> [Row] {
            rows.sorted {
                let a = key($0)
                let b = key($1)
                if a == b { return compareTitles($0, $1) }
                return ascending ? a < b : a > b
            }
        }
        switch sortColumn {
        case .title:
            return rows.sorted {
                ascending ? compareTitles($0, $1) : compareTitles($1, $0)
            }
        case .artist:
            return byString { $0.track.artist }
        case .album:
            return byString { $0.track.albumTitle }
        case .duration:
            return byValue { $0.track.duration }
        case .codec:
            return byString { $0.track.codec ?? "" }
        case .quality:
            return byValue { qualityRank($0.track) }
        case .plays:
            return byValue { $0.plays }
        case .loved:
            return byValue { $0.track.loved ? 1 : 0 }
        case .dateAdded:
            return byValue { $0.dateAdded }
        }
    }

    private func qualityRank(_ track: Track) -> Int {
        (track.isLossless ? 1 << 24 : 0) + (track.bitDepth ?? 0) * 100_000 + (track.sampleRate ?? 0)
    }
}
