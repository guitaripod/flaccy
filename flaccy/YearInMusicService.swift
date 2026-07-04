import Foundation

/// Computes Year in Music snapshots from the local `scrobbles` table. Imported
/// history rows carry no duration, so listening time falls back to the owned
/// track's real length (or a typical song length) instead of undercounting.
final class YearInMusicService {

    static let shared = YearInMusicService()

    private static let fallbackTrackSeconds = 210

    private let db = DatabaseManager.shared

    private init() {}

    func availableYears() -> [Int] {
        (try? db.scrobbleYears()) ?? []
    }

    func compute(year: Int) -> YearInMusicData {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: year)) ?? .distantPast
        let end = calendar.date(from: DateComponents(year: year + 1)) ?? .distantFuture
        let rows = (try? db.fetchScrobbleRows(from: start, to: end)) ?? []

        let durations = libraryDurations()
        var totalSeconds = 0
        var artistCounts: [String: Int] = [:]
        var albumCounts: [String: (album: String, artist: String, count: Int)] = [:]
        var trackCounts: [String: (title: String, artist: String, count: Int)] = [:]
        var dayCounts: [Date: Int] = [:]
        var hourCounts = [Int](repeating: 0, count: 24)
        var trackAlbumCounts: [String: [String: Int]] = [:]

        for row in rows {
            if row.duration > 0 {
                totalSeconds += row.duration
            } else {
                let key = LastFMStatsService.trackKey(row.trackTitle, row.artist)
                totalSeconds += durations[key] ?? Self.fallbackTrackSeconds
            }
            artistCounts[row.artist, default: 0] += 1
            let albumKey = "\(row.albumTitle)\u{0}\(row.artist)"
            albumCounts[albumKey] = (row.albumTitle, row.artist, (albumCounts[albumKey]?.count ?? 0) + 1)
            let trackKey = "\(row.trackTitle)\u{0}\(row.artist)"
            trackCounts[trackKey] = (row.trackTitle, row.artist, (trackCounts[trackKey]?.count ?? 0) + 1)
            if !row.albumTitle.isEmpty {
                trackAlbumCounts[trackKey, default: [:]][row.albumTitle, default: 0] += 1
            }
            dayCounts[calendar.startOfDay(for: row.timestamp), default: 0] += 1
            let hour = calendar.component(.hour, from: row.timestamp)
            if hour >= 0 && hour < 24 { hourCounts[hour] += 1 }
        }

        let topArtists = artistCounts.sorted { $0.value > $1.value }
            .prefix(5)
            .enumerated()
            .map { ChartArtist(rank: $0.offset + 1, name: $0.element.key, playCount: $0.element.value) }
        let topAlbums = albumCounts.values.sorted { $0.count > $1.count }
            .prefix(5)
            .enumerated()
            .map { ChartAlbum(rank: $0.offset + 1, name: $0.element.album, artistName: $0.element.artist, playCount: $0.element.count, imageURL: nil) }
        let topTracks = trackCounts.values.sorted { $0.count > $1.count }
            .prefix(5)
            .enumerated()
            .map { ChartTrack(rank: $0.offset + 1, name: $0.element.title, artistName: $0.element.artist, playCount: $0.element.count) }

        var artistTopAlbums: [String: String] = [:]
        var artistAlbumBest: [String: Int] = [:]
        for entry in albumCounts.values where !entry.album.isEmpty {
            if entry.count > (artistAlbumBest[entry.artist] ?? 0) {
                artistAlbumBest[entry.artist] = entry.count
                artistTopAlbums[entry.artist] = entry.album
            }
        }
        let trackAlbums = trackAlbumCounts.compactMapValues { $0.max { $0.value < $1.value }?.key }

        let peak = dayCounts.max { $0.value < $1.value }
        let peakHour = hourCounts.contains(where: { $0 > 0 })
            ? hourCounts.firstIndex(of: hourCounts.max() ?? 0)
            : nil

        return YearInMusicData(
            year: year,
            totalPlays: rows.count,
            totalMinutes: totalSeconds / 60,
            distinctArtists: artistCounts.count,
            distinctAlbums: albumCounts.count,
            distinctTracks: trackCounts.count,
            topArtists: topArtists,
            topAlbums: topAlbums,
            topTracks: topTracks,
            peakDay: peak?.key,
            peakDayPlays: peak?.value ?? 0,
            peakHour: peakHour,
            longestStreak: longestStreak(days: Set(dayCounts.keys), calendar: calendar),
            persona: persona(plays: rows.count, distinctArtists: artistCounts.count, hourCounts: hourCounts),
            artistTopAlbums: artistTopAlbums,
            trackAlbums: trackAlbums
        )
    }

    private func libraryDurations() -> [String: Int] {
        var durations: [String: Int] = [:]
        for track in Library.shared.allTracks where track.duration > 0 {
            durations[LastFMStatsService.trackKey(track.title, track.artist)] = Int(track.duration)
        }
        return durations
    }

    private func longestStreak(days: Set<Date>, calendar: Calendar) -> Int {
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

    private func persona(plays: Int, distinctArtists: Int, hourCounts: [Int]) -> String {
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
