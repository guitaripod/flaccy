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

    func fetchLyrics(track: String, artist: String, album: String) async -> LyricsResult? {
        if let cached = try? DatabaseManager.shared.fetchLyrics(trackTitle: track, artist: artist) {
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
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let instrumental = json?["instrumental"] as? Bool ?? false
            let syncedRaw = json?["syncedLyrics"] as? String
            let plainRaw = json?["plainLyrics"] as? String

            var syncedLines: [LyricLine]?
            if let synced = syncedRaw {
                syncedLines = parseLRC(synced)
            }

            let record = LyricsRecord(
                trackTitle: track,
                artist: artist,
                syncedLyrics: syncedRaw,
                plainLyrics: plainRaw,
                instrumental: instrumental
            )
            try? DatabaseManager.shared.saveLyrics(record)

            return LyricsResult(syncedLines: syncedLines, plainText: plainRaw, isInstrumental: instrumental)
        } catch {
            AppLogger.error("Lyrics fetch failed: \(error.localizedDescription)", category: .content)
            return nil
        }
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
