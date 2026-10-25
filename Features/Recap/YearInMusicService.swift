import FlaccyCore
import Foundation

/// Computes Year in Music snapshots from the local `scrobbles` table. Imported
/// history rows carry no duration, so listening time falls back to the owned
/// track's real length (or a typical song length) instead of undercounting.
nonisolated final class YearInMusicService: Sendable {

    static let shared = YearInMusicService()

    private let db = DatabaseManager.shared

    private init() {}

    func availableYears() -> [Int] {
        (try? db.scrobbleYears()) ?? []
    }

    @MainActor
    func compute(year: Int) -> YearInMusicData {
        compute(year: year, libraryDurations: libraryDurations())
    }

    /// Duration-injected variant callable off the main actor: the scrobble
    /// fetch and aggregation are the expensive part, and everything they
    /// touch (the database, pure math) is thread-safe.
    nonisolated func compute(year: Int, libraryDurations: [String: Int]) -> YearInMusicData {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: year)) ?? .distantPast
        let end = calendar.date(from: DateComponents(year: year + 1)) ?? .distantFuture
        let rows = (try? db.fetchScrobbleRows(from: start, to: end)) ?? []

        let durations = libraryDurations
        var totalSeconds = 0
        var keyMemo = ListenKeyMemo()
        var artists = SpellingTally()
        var albums = SpellingTally()
        var tracks = SpellingTally()
        var albumArtist: [String: String] = [:]
        var trackAlbumPlays: [String: [String: Int]] = [:]
        var dayCounts: [Date: Int] = [:]
        var hourCounts = [Int](repeating: 0, count: 24)

        for row in rows {
            let keys = keyMemo.keys(title: row.trackTitle, artist: row.artist, album: row.albumTitle)
            let trackKey = keys.title + "\u{0}" + keys.artist
            if row.duration > 0 {
                totalSeconds += row.duration
            } else {
                totalSeconds += durations[trackKey] ?? DatabaseManager.unknownPlaySeconds
            }
            let moment = Int(row.timestamp.timeIntervalSince1970)
            artists.add(key: keys.artist, name: row.artist, at: moment)
            tracks.add(key: trackKey, name: Self.pair(row.trackTitle, row.artist), at: moment)
            if !keys.album.isEmpty {
                let albumKey = keys.album + "\u{0}" + keys.artist
                albums.add(key: albumKey, name: Self.pair(row.albumTitle, row.artist), at: moment)
                albumArtist[albumKey] = keys.artist
                trackAlbumPlays[trackKey, default: [:]][albumKey, default: 0] += 1
            }
            dayCounts[calendar.startOfDay(for: row.timestamp), default: 0] += 1
            let hour = calendar.component(.hour, from: row.timestamp)
            if hour >= 0 && hour < 24 { hourCounts[hour] += 1 }
        }

        let foldedArtists = artists.folded()
        let foldedAlbums = albums.folded()
        let foldedTracks = tracks.folded()
        let artistNames = Dictionary(uniqueKeysWithValues: foldedArtists.map { ($0.key, $0.name) })
        let albumNames = Dictionary(uniqueKeysWithValues: foldedAlbums.map { ($0.key, Self.unpair($0.name).first) })

        let topArtists = Self.topFive(foldedArtists)
            .enumerated()
            .map { ChartArtist(rank: $0.offset + 1, name: $0.element.name, playCount: $0.element.plays) }
        let topAlbums = Self.topFive(foldedAlbums)
            .enumerated()
            .map { entry -> ChartAlbum in
                let parts = Self.unpair(entry.element.name)
                return ChartAlbum(rank: entry.offset + 1, name: parts.first, artistName: parts.second, playCount: entry.element.plays, imageURL: nil)
            }
        let topTracks = Self.topFive(foldedTracks)
            .enumerated()
            .map { entry -> ChartTrack in
                let parts = Self.unpair(entry.element.name)
                return ChartTrack(rank: entry.offset + 1, name: parts.first, artistName: parts.second, playCount: entry.element.plays)
            }

        var artistTopAlbums: [String: String] = [:]
        var artistAlbumBest: [String: Int] = [:]
        for entry in foldedAlbums.sorted(by: { $0.name < $1.name }) {
            guard let artistKey = albumArtist[entry.key], let artistName = artistNames[artistKey] else { continue }
            if entry.plays > (artistAlbumBest[artistName] ?? 0) {
                artistAlbumBest[artistName] = entry.plays
                artistTopAlbums[artistName] = Self.unpair(entry.name).first
            }
        }
        var trackAlbums: [String: String] = [:]
        for entry in foldedTracks {
            guard let plays = trackAlbumPlays[entry.key],
                  let best = plays.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
                  let albumName = albumNames[best.key] else { continue }
            let parts = Self.unpair(entry.name)
            trackAlbums[parts.first + "\u{0}" + parts.second] = albumName
        }

        let peak = dayCounts.max { $0.value < $1.value }
        let peakHour = hourCounts.contains(where: { $0 > 0 })
            ? hourCounts.firstIndex(of: hourCounts.max() ?? 0)
            : nil

        return YearInMusicData(
            year: year,
            totalPlays: rows.count,
            totalMinutes: totalSeconds / 60,
            distinctArtists: artists.distinct,
            distinctAlbums: albums.distinct,
            distinctTracks: tracks.distinct,
            topArtists: topArtists,
            topAlbums: topAlbums,
            topTracks: topTracks,
            peakDay: peak?.key,
            peakDayPlays: peak?.value ?? 0,
            peakHour: peakHour,
            longestStreak: longestStreak(days: Set(dayCounts.keys), calendar: calendar),
            persona: persona(plays: rows.count, distinctArtists: artists.distinct, hourCounts: hourCounts),
            artistTopAlbums: artistTopAlbums,
            trackAlbums: trackAlbums
        )
    }

    private static let pairSeparator = "\u{1F}"

    private static func pair(_ first: String, _ second: String) -> String {
        first + pairSeparator + second
    }

    private static func unpair(_ name: String) -> (first: String, second: String) {
        let parts = name.components(separatedBy: pairSeparator)
        return (first: parts[0], second: parts.count > 1 ? parts[1] : "")
    }

    private static func topFive(_ folded: [SpellingTally.Entry]) -> [SpellingTally.Entry] {
        Array(folded.sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.name < $1.name }.prefix(5))
    }

    /// Plays counted per key under every spelling heard, so each key can be
    /// named by the spelling heard most.
    private struct SpellingTally {
        struct Entry {
            let key: String
            let name: String
            let plays: Int
        }

        private var spellings: [String: [String: (plays: Int, latest: Int)]] = [:]

        var distinct: Int { spellings.count }

        mutating func add(key: String, name: String, at moment: Int) {
            let seen = spellings[key]?[name]
            spellings[key, default: [:]][name] = ((seen?.plays ?? 0) + 1, max(seen?.latest ?? moment, moment))
        }

        func folded() -> [Entry] {
            spellings.compactMap { key, names in
                let counted = names.map {
                    ListenHistory.Spelling(key: key, name: $0.key, plays: $0.value.plays, seconds: 0, latest: $0.value.latest)
                }
                return ListenHistory.foldSpellings(counted).first.map { Entry(key: key, name: $0.name, plays: $0.plays) }
            }
        }
    }

    @MainActor
    func libraryDurations() -> [String: Int] {
        LastFMStatsService.shared.libraryLengths()
    }

    nonisolated private func longestStreak(days: Set<Date>, calendar: Calendar) -> Int {
        var longest = 0
        for day in days {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day),
                  !days.contains(previous) else { continue }
            var length = 1
            var cursor = day
            while let next = calendar.date(byAdding: .day, value: 1, to: cursor), days.contains(next) {
                length += 1
                cursor = next
            }
            longest = max(longest, length)
        }
        return longest
    }

    nonisolated private func persona(plays: Int, distinctArtists: Int, hourCounts: [Int]) -> String {
        guard plays > 0 else { return "Newcomer" }
        let diversity = Double(distinctArtists) / Double(plays)
        let nightPlays = (0..<6).reduce(0) { $0 + hourCounts[$1] } + hourCounts[23]
        let nightRatio = Double(nightPlays) / Double(plays)

        if nightRatio > 0.35 { return "Night Owl" }
        if diversity > 0.6 { return "Explorer" }
        if diversity < 0.2 { return "Loyalist" }
        return "Devotee"
    }
}
