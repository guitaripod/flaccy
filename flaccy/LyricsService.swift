import Foundation

nonisolated struct LyricLine: Sendable {
    let time: TimeInterval
    let text: String
}

nonisolated struct LyricsResult: Sendable {
    let syncedLines: [LyricLine]?
    let plainText: String?
    let isInstrumental: Bool
}

final class LyricsService {

    static let shared = LyricsService()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    /// Warms the lyrics cache for a track as soon as it starts, so opening the
    /// lyrics view is instant. A no-op once the track is already cached.
    func prefetch(track: String, artist: String, album: String) {
        guard !track.isEmpty, !artist.isEmpty else { return }
        Task { _ = await fetchLyrics(track: track, artist: artist, album: album) }
    }

    private static let notFoundTTL: TimeInterval = 30 * 24 * 3600

    func fetchLyrics(track: String, artist: String, album: String) async -> LyricsResult? {
        let cached = try? DatabaseManager.shared.fetchLyrics(trackTitle: track, artist: artist)
        if let cached, !isExpiredMiss(cached) {
            var syncedLines: [LyricLine]?
            if let synced = cached.syncedLyrics {
                syncedLines = parseLRC(synced)
            }
            return LyricsResult(syncedLines: syncedLines, plainText: cached.plainLyrics, isInstrumental: cached.instrumental)
        }

        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("flaccy/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }

            if http.statusCode == 404 {
                return cacheNotFound(track: track, artist: artist, replacing: cached?.id)
            }
            guard http.statusCode == 200 else { return nil }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let instrumental = json?["instrumental"] as? Bool ?? false
            let syncedRaw = json?["syncedLyrics"] as? String
            let plainRaw = json?["plainLyrics"] as? String

            var syncedLines: [LyricLine]?
            if let synced = syncedRaw {
                syncedLines = parseLRC(synced)
            }

            let record = LyricsRecord(
                id: cached?.id,
                trackTitle: track,
                artist: artist,
                syncedLyrics: syncedRaw,
                plainLyrics: plainRaw,
                instrumental: instrumental,
                fetchedAt: Date()
            )
            try? DatabaseManager.shared.saveLyrics(record)

            return LyricsResult(syncedLines: syncedLines, plainText: plainRaw, isInstrumental: instrumental)
        } catch {
            AppLogger.error("Lyrics fetch failed: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    /// Persists an empty record when lrclib has no lyrics for the track, so
    /// subsequent plays hit the database instead of re-issuing the request.
    private func cacheNotFound(track: String, artist: String, replacing existingID: Int64?) -> LyricsResult {
        let record = LyricsRecord(
            id: existingID,
            trackTitle: track,
            artist: artist,
            syncedLyrics: nil,
            plainLyrics: nil,
            instrumental: false,
            fetchedAt: Date()
        )
        try? DatabaseManager.shared.saveLyrics(record)
        return LyricsResult(syncedLines: nil, plainText: nil, isInstrumental: false)
    }

    /// A cached row with no lyrics and no instrumental flag is a remembered
    /// lrclib miss; it expires after a month so lyrics published later are
    /// eventually fetched. Legacy miss rows without a timestamp count as expired.
    private func isExpiredMiss(_ record: LyricsRecord) -> Bool {
        guard record.syncedLyrics == nil, record.plainLyrics == nil, !record.instrumental else { return false }
        guard let fetchedAt = record.fetchedAt else { return true }
        return Date().timeIntervalSince(fetchedAt) > Self.notFoundTTL
    }

    nonisolated private func parseLRC(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for line in lrc.components(separatedBy: "\n") {
            guard line.hasPrefix("["),
                  let closeBracket = line.firstIndex(of: "]") else { continue }

            let timeStr = String(line[line.index(after: line.startIndex)..<closeBracket])
            let text = String(line[line.index(after: closeBracket)...]).trimmingCharacters(in: .whitespaces)

            let parts = timeStr.split(separator: ":")
            guard parts.count == 2,
                  let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { continue }

            let time = minutes * 60 + seconds
            if !text.isEmpty {
                lines.append(LyricLine(time: time, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }
}
