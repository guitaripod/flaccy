import Foundation
import MidgarCore

nonisolated extension ChartPeriod {
    /// The earliest instant included in this period, measured back from `now`.
    func cutoff(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .week: return calendar.date(byAdding: .day, value: -7, to: now) ?? now
        case .month: return calendar.date(byAdding: .month, value: -1, to: now) ?? now
        case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: now) ?? now
        case .sixMonths: return calendar.date(byAdding: .month, value: -6, to: now) ?? now
        case .year: return calendar.date(byAdding: .year, value: -1, to: now) ?? now
        case .allTime: return .distantPast
        }
    }

    /// The earliest instant included in this period, measured back from now.
    var cutoffDate: Date { cutoff(now: Date()) }
}

nonisolated struct RecapMetrics: Sendable {
    let totalPlays: Int
    let totalMinutes: Int
    let topArtists: [ChartArtist]
    let topAlbums: [ChartAlbum]
    let topTracks: [ChartTrack]
    let listeningClock: [Int]
    let streakDays: Int
    let heatmap: [Date: Int]
    let calendarHeatmap: [Date: Int]
    let persona: String
    let previousPlays: Int?
    let previousMinutes: Int?
    let previousSpanDays: Int?
}

/// Local listening statistics computed entirely from the `scrobbles` table so
/// they work offline. `importHistory()` backfills that table from Last.fm; every
/// other method reads only local rows.
nonisolated final class LastFMStatsService: @unchecked Sendable {

    static let shared = LastFMStatsService()

    static let firstDatedScrobble = DatabaseManager.firstDatedScrobble

    /// The heatmap always shows at least this many Sunday-aligned columns.
    static let calendarHeatmapWeeks = 53

    private static let bucketSeconds = 900
    private static let secondsPerDay = 86_400

    private let db = DatabaseManager.shared
    private let lastFM = LastFMService.shared

    private init() {}

    var scrobbleRevision: Int { db.scrobbleRevision }

    /// Computes every Recap metric from aggregates the database folds itself,
    /// so no scrobble row is ever decoded: the totals and the three top lists
    /// are `GROUP BY` results (the totals are the sums of the per-artist groups), and the clock, heatmap, streak and persona's night
    /// ratio all come from one quarter-hour histogram of the dated plays. The
    /// histogram is read in two disjoint pieces, before and inside the period,
    /// so a short period never pays for the long calendar around it.
    func recapMetrics(period: ChartPeriod, now: Date = Date(), calendar: Calendar = .current) -> RecapMetrics {
        let cutoff = period.cutoff(now: now, calendar: calendar)
        let artistCounts = (try? db.scrobbleArtistCounts(from: cutoff, to: .distantFuture)) ?? []
        let totals = (plays: artistCounts.reduce(0) { $0 + $1.count }, seconds: artistCounts.reduce(0) { $0 + $1.seconds })
        let albums = (try? db.scrobbleTopAlbums(from: cutoff, to: .distantFuture, limit: 9)) ?? []
        let tracks = (try? db.scrobbleTopTracks(from: cutoff, to: .distantFuture, limit: 10)) ?? []

        let zone = calendar.timeZone
        let periodFrom = max(cutoff, Self.firstDatedScrobble)
        let wideFrom = calendarWindowStart(period: period, periodFrom: periodFrom, now: now, calendar: calendar)
        let during = Self.tally((try? db.scrobbleQuarterHourCounts(from: periodFrom, to: .distantFuture)) ?? [], zone: zone)
        var calendarTally = during
        if wideFrom < periodFrom {
            let before = Self.tally((try? db.scrobbleQuarterHourCounts(from: wideFrom, to: periodFrom)) ?? [], zone: zone)
            calendarTally.merge(before)
        }

        let streak = streakDays(calendarDays: calendarTally.days, wideFrom: wideFrom, now: now, calendar: calendar)
        let previous = previousWindowTotals(period: period, cutoff: cutoff, now: now)
        return RecapMetrics(
            totalPlays: totals.plays,
            totalMinutes: totals.seconds / 60,
            topArtists: Self.topArtists(from: artistCounts, limit: 10),
            topAlbums: albums.enumerated().map {
                ChartAlbum(rank: $0.offset + 1, name: $0.element.album, artistName: $0.element.artist, playCount: $0.element.count, imageURL: nil)
            },
            topTracks: tracks.enumerated().map {
                ChartTrack(rank: $0.offset + 1, name: $0.element.title, artistName: $0.element.artist, playCount: $0.element.count)
            },
            listeningClock: during.clock,
            streakDays: streak,
            heatmap: during.heatmap(calendar: calendar),
            calendarHeatmap: calendarTally.heatmap(calendar: calendar),
            persona: Self.persona(
                plays: totals.plays,
                distinctArtists: Set(artistCounts.map { $0.artist.lowercased() }).count,
                clock: during.clock
            ),
            previousPlays: previous?.plays,
            previousMinutes: previous?.minutes,
            previousSpanDays: previous?.spanDays
        )
    }

    func topArtists(period: ChartPeriod, limit: Int = 50) -> [ChartArtist] {
        let counts = (try? db.scrobbleArtistCounts(from: period.cutoffDate, to: .distantFuture)) ?? []
        return Self.topArtists(from: counts, limit: limit)
    }

    /// Per-track scrobble counts over the period, keyed by a lowercased
    /// `title\0artist` composite matching `StationBuilder`/`LovedTracksService`.
    /// Folded by the database, so a library with a hundred thousand scrobbles
    /// costs a `GROUP BY` instead of a full-table decode.
    func scrobbleCounts(period: ChartPeriod) -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in (try? db.scrobbleTrackCounts(from: period.cutoffDate, to: .distantFuture)) ?? [] {
            counts[Self.trackKey(row.title, row.artist), default: 0] += row.count
        }
        return counts
    }

    static func trackKey(_ title: String, _ artist: String) -> String {
        "\(title.lowercased())\u{0}\(artist.lowercased())"
    }

    /// Where the heatmap's data starts: this week's Sunday minus 52 weeks, or
    /// the period's own first Sunday when that is earlier, or the first dated
    /// play for All Time. A local midnight, except for All Time.
    private func calendarWindowStart(period: ChartPeriod, periodFrom: Date, now: Date, calendar: Calendar) -> Date {
        guard period != .allTime else { return Self.firstDatedScrobble }
        let trailing = Self.sunday(onOrBefore: now, calendar: calendar)
            .flatMap { calendar.date(byAdding: .day, value: -7 * (Self.calendarHeatmapWeeks - 1), to: $0) }
        let periodStart = Self.sunday(onOrBefore: periodFrom, calendar: calendar)
        let earliest = [trailing, periodStart].compactMap { $0 }.min() ?? periodFrom
        return max(earliest, Self.firstDatedScrobble)
    }

    private static func sunday(onOrBefore date: Date, calendar: Calendar) -> Date? {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day) - 1
        return calendar.date(byAdding: .day, value: -weekday, to: day)
    }

    /// Consecutive days ending today with a play, counted from the days already
    /// read for the heatmap. Only a streak that runs off the start of that
    /// window reads further back, one calendar-sized chunk at a time and only
    /// until the first gap, so the usual case touches no extra rows.
    private func streakDays(calendarDays: [Int: Int], wideFrom: Date, now: Date, calendar: Calendar) -> Int {
        let zone = calendar.timeZone
        var day = Self.localTime(of: Int(now.timeIntervalSince1970), zone: zone).day
        var streak = 0
        while calendarDays[day] != nil {
            streak += 1
            day -= 1
        }
        var floor = wideFrom
        while floor > Self.firstDatedScrobble, day < Self.localTime(of: Int(floor.timeIntervalSince1970), zone: zone).day {
            let chunkSpan = TimeInterval(7 * Self.calendarHeatmapWeeks * Self.secondsPerDay)
            let chunkFrom = max(Self.firstDatedScrobble, calendar.startOfDay(for: floor.addingTimeInterval(-chunkSpan)))
            let older = Self.tally((try? db.scrobbleQuarterHourCounts(from: chunkFrom, to: floor)) ?? [], zone: zone)
            while older.days[day] != nil {
                streak += 1
                day -= 1
            }
            floor = chunkFrom
        }
        return streak
    }

    /// The same totals over the window of equal length just before the period,
    /// so a tile can say whether this stretch beat the last one.
    private func previousWindowTotals(
        period: ChartPeriod, cutoff: Date, now: Date
    ) -> (plays: Int, minutes: Int, spanDays: Int)? {
        guard period != .allTime else { return nil }
        let span = now.timeIntervalSince(cutoff)
        let totals = (try? db.scrobbleTotals(from: cutoff.addingTimeInterval(-span), to: cutoff)) ?? (plays: 0, seconds: 0)
        return (totals.plays, totals.seconds / 60, Int((span / TimeInterval(Self.secondsPerDay)).rounded()))
    }

    /// Dated plays folded into local days and hours. `days` is keyed by the
    /// local day number (days since 1970 in the viewer's zone) and remembers one
    /// zone offset per day so the day can be turned back into a `Date`.
    private struct Tally {
        var days: [Int: Int] = [:]
        var offsets: [Int: Int] = [:]
        var clock = [Int](repeating: 0, count: 24)

        mutating func merge(_ other: Tally) {
            for (day, count) in other.days { days[day, default: 0] += count }
            for (day, offset) in other.offsets where offsets[day] == nil { offsets[day] = offset }
        }

        func heatmap(calendar: Calendar) -> [Date: Int] {
            var map: [Date: Int] = [:]
            map.reserveCapacity(days.count)
            for (day, count) in days {
                let noonUTC = TimeInterval(day * LastFMStatsService.secondsPerDay + LastFMStatsService.secondsPerDay / 2)
                let noonLocal = Date(timeIntervalSince1970: noonUTC - TimeInterval(offsets[day] ?? 0))
                map[calendar.startOfDay(for: noonLocal), default: 0] += count
            }
            return map
        }
    }

    private static func tally(_ buckets: [(bucket: Int, count: Int)], zone: TimeZone) -> Tally {
        var tally = Tally()
        for (bucket, count) in buckets {
            let local = localTime(of: bucket * bucketSeconds, zone: zone)
            tally.days[local.day, default: 0] += count
            if tally.offsets[local.day] == nil { tally.offsets[local.day] = local.offset }
            tally.clock[local.hour] += count
        }
        return tally
    }

    private static func localTime(of seconds: Int, zone: TimeZone) -> (day: Int, hour: Int, offset: Int) {
        let offset = zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds)))
        let local = seconds + offset
        return (local / secondsPerDay, local % secondsPerDay / 3600, offset)
    }

    private static func topArtists(from counts: [(artist: String, count: Int, seconds: Int)], limit: Int) -> [ChartArtist] {
        counts.sorted { $0.count != $1.count ? $0.count > $1.count : $0.artist < $1.artist }
            .prefix(limit)
            .enumerated()
            .map { ChartArtist(rank: $0.offset + 1, name: $0.element.artist, playCount: $0.element.count) }
    }

    /// Night plays are measured against dated plays only: an undated row has no
    /// hour, so counting it in the denominator would dilute the ratio.
    private static func persona(plays: Int, distinctArtists: Int, clock: [Int]) -> String {
        guard plays > 0 else { return "Newcomer" }
        let diversity = Double(distinctArtists) / Double(plays)
        let nightPlays = (0..<6).reduce(0) { $0 + clock[$1] } + clock[23]
        let datedPlays = clock.reduce(0, +)
        let nightRatio = Double(nightPlays) / Double(max(datedPlays, 1))

        if nightRatio > 0.35 { return "Night Owl" }
        if diversity > 0.6 { return "Explorer" }
        if diversity < 0.2 { return "Loyalist" }
        return "Devotee"
    }

    /// Backfills the local `scrobbles` table from Last.fm recent-tracks pages,
    /// deduplicating against existing rows by timestamp+track. The page bound
    /// only guards against a runaway pagination loop; at 200 rows per page it
    /// admits two million scrobbles, so any real account imports completely.
    @concurrent
    func importHistory(maxPages: Int = 10_000) async {
        guard lastFM.isAuthenticated else { return }

        var seen = (try? db.scrobbleIdentities()) ?? []

        var page = 1
        var totalPages = 1
        var imported = 0
        repeat {
            let result = await lastFM.fetchRecentTracks(page: page, limit: 200)
            totalPages = result.totalPages
            var batch: [ScrobbleRecord] = []
            for track in result.tracks {
                guard let uts = track.uts else { continue }
                let timestamp = Date(timeIntervalSince1970: TimeInterval(uts))
                guard seen.insert(DatabaseManager.scrobbleIdentity(timestamp: timestamp, title: track.name)).inserted else { continue }
                batch.append(ScrobbleRecord(
                    id: nil,
                    trackTitle: track.name,
                    artist: track.artist,
                    albumTitle: track.album,
                    timestamp: timestamp,
                    duration: 0,
                    submitted: true
                ))
            }
            do {
                try db.insertScrobbles(batch)
                imported += batch.count
            } catch {
                MidgarLog.error("Import scrobble page \(page) failed: \(error.localizedDescription)", category: .database)
            }
            page += 1
        } while page <= totalPages && page <= maxPages

        do {
            try db.reconcilePlayCountsFromScrobbles()
        } catch {
            MidgarLog.error("Play-count reconcile failed: \(error.localizedDescription)", category: .database)
        }
        MidgarLog.info("Imported \(imported) historical scrobbles", category: .sync)
    }
}
