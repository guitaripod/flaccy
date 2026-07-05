import Foundation

extension ChartPeriod {
    /// The earliest instant included in this period, measured back from now.
    var cutoffDate: Date {
        let now = Date()
        let calendar = Calendar.current
        switch self {
        case .week: return calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .month: return calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: now) ?? now
        case .sixMonths: return calendar.date(byAdding: .month, value: -6, to: now) ?? now
        case .year: return calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .allTime: return .distantPast
        }
    }
}

/// Local listening statistics computed entirely from the `scrobbles` table so
/// they work offline. `importHistory()` backfills that table from Last.fm; every
/// other method reads only local rows.
nonisolated final class LastFMStatsService: @unchecked Sendable {

    static let shared = LastFMStatsService()

    private let db = DatabaseManager.shared
    private let lastFM = LastFMService.shared

    private init() {}

    private func rows(in period: ChartPeriod) -> [ScrobbleRecord] {
        let all = (try? db.fetchAllScrobbleRows()) ?? []
        guard period != .allTime else { return all }
        let cutoff = period.cutoffDate
        return all.filter { $0.timestamp >= cutoff }
    }

    func topArtists(period: ChartPeriod, limit: Int = 50) -> [ChartArtist] {
        var counts: [String: Int] = [:]
        for row in rows(in: period) { counts[row.artist, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }
            .prefix(limit)
            .enumerated()
            .map { ChartArtist(rank: $0.offset + 1, name: $0.element.key, playCount: $0.element.value) }
    }

    func topAlbums(period: ChartPeriod, limit: Int = 50) -> [ChartAlbum] {
        var counts: [String: (album: String, artist: String, count: Int)] = [:]
        for row in rows(in: period) {
            let key = "\(row.albumTitle)\u{0}\(row.artist)"
            let existing = counts[key]
            counts[key] = (row.albumTitle, row.artist, (existing?.count ?? 0) + 1)
        }
        return counts.values.sorted { $0.count > $1.count }
            .prefix(limit)
            .enumerated()
            .map { ChartAlbum(rank: $0.offset + 1, name: $0.element.album, artistName: $0.element.artist, playCount: $0.element.count, imageURL: nil) }
    }

    func topTracks(period: ChartPeriod, limit: Int = 50) -> [ChartTrack] {
        var counts: [String: (title: String, artist: String, count: Int)] = [:]
        for row in rows(in: period) {
            let key = "\(row.trackTitle)\u{0}\(row.artist)"
            let existing = counts[key]
            counts[key] = (row.trackTitle, row.artist, (existing?.count ?? 0) + 1)
        }
        return counts.values.sorted { $0.count > $1.count }
            .prefix(limit)
            .enumerated()
            .map { ChartTrack(rank: $0.offset + 1, name: $0.element.title, artistName: $0.element.artist, playCount: $0.element.count) }
    }

    /// Per-track scrobble counts over the period, keyed by a lowercased
    /// `title\0artist` composite matching `StationBuilder`/`LovedTracksService`.
    func scrobbleCounts(period: ChartPeriod) -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in rows(in: period) {
            counts[Self.trackKey(row.trackTitle, row.artist), default: 0] += 1
        }
        return counts
    }

    static func trackKey(_ title: String, _ artist: String) -> String {
        "\(title.lowercased())\u{0}\(artist.lowercased())"
    }

    func totalPlays(period: ChartPeriod = .allTime) -> Int {
        rows(in: period).count
    }

    func totalMinutes(period: ChartPeriod = .allTime) -> Int {
        rows(in: period).reduce(0) { $0 + $1.duration } / 60
    }

    /// Play counts bucketed by hour-of-day (index 0...23) in the local calendar.
    func listeningClock(period: ChartPeriod = .allTime) -> [Int] {
        var buckets = [Int](repeating: 0, count: 24)
        let calendar = Calendar.current
        for row in rows(in: period) {
            let hour = calendar.component(.hour, from: row.timestamp)
            if hour >= 0 && hour < 24 { buckets[hour] += 1 }
        }
        return buckets
    }

    /// Number of consecutive days ending today on which at least one scrobble
    /// happened.
    func currentStreakDays() -> Int {
        let all = (try? db.fetchAllScrobbleRows()) ?? []
        guard !all.isEmpty else { return 0 }
        let calendar = Calendar.current
        let days = Set(all.map { calendar.startOfDay(for: $0.timestamp) })

        var streak = 0
        var day = calendar.startOfDay(for: Date())
        while days.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    /// Play counts keyed by the start of each day, over the given period.
    func dayHeatmap(period: ChartPeriod = .year) -> [Date: Int] {
        var map: [Date: Int] = [:]
        let calendar = Calendar.current
        for row in rows(in: period) {
            let day = calendar.startOfDay(for: row.timestamp)
            map[day, default: 0] += 1
        }
        return map
    }

    func persona(period: ChartPeriod = .allTime) -> String {
        let scrobbles = rows(in: period)
        guard !scrobbles.isEmpty else { return "Newcomer" }
        let distinctArtists = Set(scrobbles.map { $0.artist.lowercased() }).count
        let plays = scrobbles.count
        let diversity = Double(distinctArtists) / Double(plays)
        let clock = listeningClock(period: period)
        let nightPlays = (0..<6).reduce(0) { $0 + clock[$1] } + clock[23]
        let nightRatio = Double(nightPlays) / Double(max(plays, 1))

        if nightRatio > 0.35 { return "Night Owl" }
        if diversity > 0.6 { return "Explorer" }
        if diversity < 0.2 { return "Loyalist" }
        return "Devotee"
    }

    /// Backfills the local `scrobbles` table from Last.fm recent-tracks pages,
    /// deduplicating against existing rows by timestamp+track. The page bound
    /// only guards against a runaway pagination loop; at 200 rows per page it
    /// admits two million scrobbles, so any real account imports completely.
    func importHistory(maxPages: Int = 10_000) async {
        guard lastFM.isAuthenticated else { return }

        let existing = (try? db.fetchAllScrobbleRows()) ?? []
        var seen = Set(existing.compactMap { row -> String? in
            "\(Int(row.timestamp.timeIntervalSince1970))\u{0}\(row.trackTitle.lowercased())"
        })

        var page = 1
        var totalPages = 1
        var imported = 0
        repeat {
            let result = await lastFM.fetchRecentTracks(page: page, limit: 200)
            totalPages = result.totalPages
            for track in result.tracks {
                guard let uts = track.uts else { continue }
                let key = "\(uts)\u{0}\(track.name.lowercased())"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                let record = ScrobbleRecord(
                    id: nil,
                    trackTitle: track.name,
                    artist: track.artist,
                    albumTitle: track.album,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(uts)),
                    duration: 0,
                    submitted: true
                )
                do {
                    try db.insertScrobble(record)
                    imported += 1
                } catch {
                    AppLogger.error("Import scrobble failed: \(error.localizedDescription)", category: .database)
                }
            }
            page += 1
        } while page <= totalPages && page <= maxPages

        AppLogger.info("Imported \(imported) historical scrobbles", category: .sync)
    }
}
