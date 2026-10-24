import MidgarCore
#if DEBUG
import AppKit

/// Headless support for the Stats and Songs verification: seeds recent listening
/// onto the fictional screenshot library, and times the Recap snapshot against a
/// synthetic history the size of a real imported Last.fm account.
enum DebugStatsDrive {

    private struct SplitMix {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        mutating func unit() -> Double {
            Double(next() >> 11) / Double(1 << 53)
        }
    }

    static func runIfRequested() {
        if let count = value(after: "--bench-stats").flatMap(Int.init) {
            Task.detached(priority: .userInitiated) {
                await bench(scrobbleCount: count)
            }
        }
    }

    static var wantsRecentListening: Bool {
        CommandLine.arguments.contains("--seed-recent-scrobbles")
    }

    private static func value(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func report(_ line: String) {
        MidgarLog.info(line, category: .performance)
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "stats-bench.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func milliseconds(_ body: () -> Void) -> Double {
        let started = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    }

    /// Inserts a synthetic history shaped like an imported account: a long
    /// skewed tail since 2009, a month of daily listening ending today, and the
    /// 1970 rows an old scrobbler left behind.
    private static func seedSyntheticHistory(count: Int) {
        let db = DatabaseManager.shared
        var random = SplitMix(state: 42)
        let now = Date()
        let start = Date(timeIntervalSince1970: 1_230_768_000)
        let span = now.timeIntervalSince(start)
        var batch: [ScrobbleRecord] = []
        batch.reserveCapacity(5_000)

        func flush() {
            try? db.insertScrobbles(batch)
            batch.removeAll(keepingCapacity: true)
        }

        for index in 0..<count {
            let artist = Int(pow(random.unit(), 3) * 2_500)
            let album = Int(random.next() % 4)
            let track = Int(pow(random.unit(), 2) * 12)
            let timestamp: Date
            if index < 235 {
                timestamp = Date(timeIntervalSince1970: TimeInterval(index + 1))
            } else {
                timestamp = leavingGap(start.addingTimeInterval(span * pow(random.unit(), 0.6)), now: now)
            }
            batch.append(ScrobbleRecord(
                id: nil,
                trackTitle: "Track \(artist)-\(album)-\(track)",
                artist: "Artist \(artist)",
                albumTitle: "Album \(artist)-\(album)",
                timestamp: timestamp,
                duration: timestamp < now.addingTimeInterval(-86_400 * 700) ? 0 : 200,
                submitted: true
            ))
            if batch.count == 5_000 { flush() }
        }
        for day in 0..<30 {
            for slot in 0..<5 {
                let timestamp = now.addingTimeInterval(-Double(day) * 86_400 - Double(slot) * 1_800 - 60)
                batch.append(ScrobbleRecord(
                    id: nil, trackTitle: "Track 1-0-\(slot)", artist: "Artist 1", albumTitle: "Album 1-0",
                    timestamp: timestamp, duration: 200, submitted: true
                ))
            }
        }
        flush()
    }

    /// Keeps a few days with no plays about six weeks back, so the streak the
    /// benchmark measures is a realistic forty days and not the whole table.
    private static func leavingGap(_ timestamp: Date, now: Date) -> Date {
        let age = now.timeIntervalSince(timestamp)
        return age > 40 * 86_400 && age < 45 * 86_400 ? timestamp.addingTimeInterval(-10 * 86_400) : timestamp
    }

    private static func bench(scrobbleCount: Int) async {
        let existing = (try? DatabaseManager.shared.scrobbleCountInRange(from: .distantPast, to: .distantFuture)) ?? 0
        if existing < scrobbleCount {
            let seeded = milliseconds { seedSyntheticHistory(count: scrobbleCount) }
            report("StatsBench seeded \(scrobbleCount) scrobbles in \(Int(seeded)) ms")
        }
        let total = (try? DatabaseManager.shared.scrobbleCountInRange(from: .distantPast, to: .distantFuture)) ?? 0
        report("StatsBench table holds \(total) scrobbles")
        let stats = LastFMStatsService.shared
        for period in [ChartPeriod.week, .allTime] {
            let cold = milliseconds { _ = stats.recapMetrics(period: period) }
            let warm = milliseconds { _ = stats.recapMetrics(period: period) }
            report("StatsBench snapshot \(period.rawValue): \(Int(cold)) ms cold, \(Int(warm)) ms warm")
        }
        let db = DatabaseManager.shared
        let from = Date.distantPast
        let to = Date.distantFuture
        report("StatsBench   artists: \(Int(milliseconds { _ = try? db.scrobbleArtistCounts(from: from, to: to) })) ms")
        report("StatsBench   albums: \(Int(milliseconds { _ = try? db.scrobbleTopAlbums(from: from, to: to, limit: 9) })) ms")
        report("StatsBench   tracks: \(Int(milliseconds { _ = try? db.scrobbleTopTracks(from: from, to: to, limit: 10) })) ms")
        report("StatsBench   buckets: \(Int(milliseconds { _ = try? db.scrobbleQuarterHourCounts(from: LastFMStatsService.firstDatedScrobble, to: to) })) ms")
        let counts = milliseconds { _ = stats.scrobbleCounts(period: .allTime) }
        report("StatsBench scrobbleCounts allTime: \(Int(counts)) ms")
        let metrics = stats.recapMetrics(period: .allTime)
        let datedPlays = metrics.listeningClock.reduce(0, +)
        report(
            "StatsBench allTime plays \(metrics.totalPlays), dated plays \(datedPlays), "
            + "heatmap days \(metrics.calendarHeatmap.count), streak \(metrics.streakDays), persona \(metrics.persona)"
        )
    }

    /// A year of plausible listening ending today, drawn from the songs the
    /// fictional library really holds so the Songs chips and the Recap agree:
    /// busier evenings, quiet days, a live streak, and a week that beats the
    /// one before it.
    static func seedRecentListening() async {
        var attempts = 0
        while Library.shared.allTracks.isEmpty, attempts < 40 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        let tracks = Library.shared.allTracks.sorted { $0.fileURL.path < $1.fileURL.path }
        let now = Date()
        let recent = (try? DatabaseManager.shared.scrobbleCountInRange(from: now.addingTimeInterval(-7 * 86_400), to: .distantFuture)) ?? 0
        guard !tracks.isEmpty, recent < 20 else { return }

        var random = SplitMix(state: 7)
        let calendar = Calendar.current
        let hours = [8, 9, 12, 13, 17, 18, 19, 20, 20, 21, 21, 22, 23, 0, 1]
        var batch: [ScrobbleRecord] = []
        for day in 0..<400 {
            guard let base = calendar.date(byAdding: .day, value: -day, to: calendar.startOfDay(for: now)) else { continue }
            let quiet = day > 11 && random.unit() < 0.28
            let weekend = calendar.isDateInWeekend(base)
            let count = quiet ? 0 : Int(random.unit() * 5) + (weekend ? 5 : 3) + (day < 7 ? 2 : 0)
            for _ in 0..<count {
                let hour = hours[Int(random.next() % UInt64(hours.count))]
                let evening = base.addingTimeInterval(Double(hour) * 3_600 + random.unit() * 3_300)
                let when = day == 0 ? max(base, now.addingTimeInterval(-60 - random.unit() * 1_200)) : evening
                guard when < now else { continue }
                let track = tracks[Int(pow(random.unit(), 2.2) * Double(tracks.count))]
                batch.append(ScrobbleRecord(
                    id: nil, trackTitle: track.title, artist: track.artist, albumTitle: track.albumTitle,
                    timestamp: when, duration: Int(track.duration), submitted: true
                ))
            }
        }
        try? DatabaseManager.shared.insertScrobbles(batch)
        MidgarLog.info("DebugStatsDrive: seeded \(batch.count) recent scrobbles over \(tracks.count) tracks", category: .general)
    }
}
#endif
