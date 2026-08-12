import AVFoundation
import Foundation

nonisolated struct LyricLine: Sendable {
    let time: TimeInterval
    let text: String
}

nonisolated struct LyricsResult: Sendable {
    let syncedLines: [LyricLine]?
    let plainText: String?
    let isInstrumental: Bool

    var isEmpty: Bool {
        !isInstrumental && (syncedLines?.isEmpty ?? true) && (plainText?.isEmpty ?? true)
    }
}

/// Separates "lrclib has nothing for this track" from "we couldn't ask it".
/// A miss is remembered (and expires); a failure is not, so a flaky network
/// leaves a Retry rather than a permanently blank panel.
nonisolated enum LyricsOutcome: Sendable {
    case found(LyricsResult)
    case missing
    case failed
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
    func prefetch(track: String, artist: String, album: String, fileURL: URL? = nil, duration: TimeInterval = 0) {
        guard !track.isEmpty, !artist.isEmpty else { return }
        let cached = try? DatabaseManager.shared.fetchLyrics(trackTitle: track, artist: artist)
        if let cached, !isExpiredMiss(cached) { return }
        Task {
            _ = await fetchLyrics(
                track: track, artist: artist, album: album, fileURL: fileURL, duration: duration
            )
        }
    }

    /// How long a remembered miss stands before lrclib is asked again — the
    /// corpus is community-contributed and grows.
    private static let notFoundTTL: TimeInterval = 30 * 24 * 3600
    /// Two pressings of the same song can differ by a few seconds; beyond this
    /// the timings would be useless, so a search candidate is rejected outright.
    private static let maxDurationDrift: TimeInterval = 15
    /// Below this a search candidate is a different song, not a near miss.
    private static let acceptedScore = 0.80

    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "flaccy/\(version) (https://github.com/guitaripod/flaccy)"
    }

    /// Resolution order: the local database cache, then lyrics the user keeps
    /// alongside the audio (an `.lrc` sidecar or an embedded tag), then lrclib.
    func fetchLyrics(
        track: String, artist: String, album: String,
        fileURL: URL? = nil, duration: TimeInterval = 0
    ) async -> LyricsOutcome {
        let cached = try? DatabaseManager.shared.fetchLyrics(trackTitle: track, artist: artist)
        if let cached, !isExpiredMiss(cached) {
            let result = LyricsResult(
                syncedLines: cached.syncedLyrics.map(Self.parseLRC),
                plainText: cached.plainLyrics,
                isInstrumental: cached.instrumental
            )
            return result.isEmpty ? .missing : .found(result)
        }

        if let fileURL, let local = await Self.readLocalLyrics(at: fileURL) {
            save(track: track, artist: artist, synced: local.synced, plain: local.plain, instrumental: false, replacing: cached?.id)
            return .found(LyricsResult(
                syncedLines: local.synced.map(Self.parseLRC),
                plainText: local.plain,
                isInstrumental: false
            ))
        }

        switch await lookupRemote(track: track, artist: artist, album: album, duration: duration) {
        case .found(let synced, let plain, let instrumental):
            save(track: track, artist: artist, synced: synced, plain: plain, instrumental: instrumental, replacing: cached?.id)
            return .found(LyricsResult(
                syncedLines: synced.map(Self.parseLRC), plainText: plain, isInstrumental: instrumental
            ))
        case .missing:
            save(track: track, artist: artist, synced: nil, plain: nil, instrumental: false, replacing: cached?.id)
            AppLogger.info("No lyrics for \(track) — \(artist) (cached miss)", category: .content)
            return .missing
        case .failed:
            return .failed
        }
    }

    private func save(
        track: String, artist: String, synced: String?, plain: String?,
        instrumental: Bool, replacing existingID: Int64?
    ) {
        let record = LyricsRecord(
            id: existingID,
            trackTitle: track,
            artist: artist,
            syncedLyrics: synced,
            plainLyrics: plain,
            instrumental: instrumental,
            fetchedAt: Date()
        )
        try? DatabaseManager.shared.saveLyrics(record)
    }

    /// A cached row with no lyrics and no instrumental flag is a remembered
    /// lrclib miss; it expires after a month so lyrics published later are
    /// eventually fetched. Legacy miss rows without a timestamp count as expired.
    private func isExpiredMiss(_ record: LyricsRecord) -> Bool {
        guard record.syncedLyrics == nil, record.plainLyrics == nil, !record.instrumental else { return false }
        guard let fetchedAt = record.fetchedAt else { return true }
        return Date().timeIntervalSince(fetchedAt) > Self.notFoundTTL
    }

    private enum Remote {
        case found(synced: String?, plain: String?, instrumental: Bool)
        case missing
        case failed
    }

    /// lrclib's exact-match endpoint is strict about the album name, which is
    /// the single most common cause of a false 404. So: try the full signature,
    /// then drop the album, then fall back to the fuzzy search endpoint and rank
    /// its results here (the endpoint itself is duration-blind).
    private func lookupRemote(track: String, artist: String, album: String, duration: TimeInterval) async -> Remote {
        let exact = await getExact(track: track, artist: artist, album: album, duration: duration)
        if case .missing = exact {} else { return exact }

        if !album.trimmingCharacters(in: .whitespaces).isEmpty {
            let withoutAlbum = await getExact(track: track, artist: artist, album: "", duration: duration)
            if case .missing = withoutAlbum {} else { return withoutAlbum }
        }
        return await searchFallback(track: track, artist: artist, album: album, duration: duration)
    }

    private func getExact(track: String, artist: String, album: String, duration: TimeInterval) async -> Remote {
        var items = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if !album.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        guard let data = await get(path: "/api/get", items: items) else { return .failed }
        switch data {
        case .notFound: return .missing
        case .body(let body):
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return .missing }
            return Self.record(from: json)
        }
    }

    private func searchFallback(track: String, artist: String, album: String, duration: TimeInterval) async -> Remote {
        let items = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        guard let data = await get(path: "/api/search", items: items) else { return .failed }
        guard case .body(let body) = data else { return .missing }
        guard let candidates = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { return .missing }
        let best = candidates
            .compactMap { candidate -> (Double, [String: Any])? in
                guard let score = Self.score(
                    candidate: candidate, track: track, artist: artist, album: album, duration: duration
                ) else { return nil }
                return (score, candidate)
            }
            .max { $0.0 < $1.0 }
        guard let best, best.0 >= Self.acceptedScore else { return .missing }
        AppLogger.info(
            "lrclib search matched \(track) — \(artist) (score \(String(format: "%.2f", best.0)))",
            category: .content
        )
        return Self.record(from: best.1)
    }

    private enum Fetched {
        case body(Data)
        case notFound
    }

    /// `nil` means the request itself failed — a different thing from a 404.
    private func get(path: String, items: [URLQueryItem]) async -> Fetched? {
        var components = URLComponents(string: "https://lrclib.net\(path)")!
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 404 { return .notFound }
            guard http.statusCode == 200 else { return nil }
            return .body(data)
        } catch {
            AppLogger.error("Lyrics request failed: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    private static func record(from json: [String: Any]) -> Remote {
        let synced = (json["syncedLyrics"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let plain = (json["plainLyrics"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let instrumental = json["instrumental"] as? Bool ?? false
        if synced == nil, plain == nil, !instrumental { return .missing }
        return .found(synced: synced, plain: plain, instrumental: instrumental)
    }

    /// Weighted similarity across the fields lrclib returns. Duration carries
    /// real weight because it is what distinguishes pressings whose timings
    /// differ, and a large drift disqualifies a candidate outright.
    static func score(
        candidate: [String: Any], track: String, artist: String, album: String, duration: TimeInterval
    ) -> Double? {
        let candidateDuration = (candidate["duration"] as? NSNumber)?.doubleValue ?? 0
        if duration > 0, candidateDuration > 0, abs(duration - candidateDuration) > maxDurationDrift {
            return nil
        }
        let durationScore: Double
        if duration > 0, candidateDuration > 0 {
            durationScore = 1 - min(abs(duration - candidateDuration) / maxDurationDrift, 1)
        } else {
            durationScore = 0.5
        }
        let hasSynced = !((candidate["syncedLyrics"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return 0.35 * similarity(track, candidate["trackName"] as? String ?? "")
            + 0.30 * similarity(artist, candidate["artistName"] as? String ?? "")
            + 0.25 * durationScore
            + 0.06 * (hasSynced ? 1 : 0)
            + 0.04 * similarity(album, candidate["albumName"] as? String ?? "")
    }

    /// Case- and punctuation-insensitive token overlap (Dice coefficient over
    /// words), enough to tell "Song (Remastered 2011)" from a different song.
    static func similarity(_ left: String, _ right: String) -> Double {
        let tokens = { (text: String) -> [String] in
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let (a, b) = (tokens(left), tokens(right))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let shared = a.filter { b.contains($0) }.count
        return 2 * Double(shared) / Double(a.count + b.count)
    }

    struct LocalLyrics {
        let synced: String?
        let plain: String?
    }

    /// Lyrics the user curated themselves, in the order other players look: an
    /// `.lrc`/`.elrc` sidecar next to the audio, then the file's own tags. Never
    /// written back — the library is the user's.
    static func readLocalLyrics(at fileURL: URL) async -> LocalLyrics? {
        for ext in ["lrc", "elrc"] {
            let sidecar = fileURL.deletingPathExtension().appendingPathExtension(ext)
            if let text = try? String(contentsOf: sidecar, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AppLogger.info("Using lyrics sidecar \(sidecar.lastPathComponent)", category: .content)
                return classify(text)
            }
        }
        if let tagged = await taggedLyrics(at: fileURL) { return classify(tagged) }
        return nil
    }

    private static func classify(_ text: String) -> LocalLyrics {
        let stripped = stripWordTimestamps(text)
        return parseLRC(stripped).isEmpty
            ? LocalLyrics(synced: nil, plain: stripped)
            : LocalLyrics(synced: stripped, plain: nil)
    }

    private static func taggedLyrics(at fileURL: URL) async -> String? {
        let asset = AVURLAsset(url: fileURL)
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        for item in metadata {
            let key = (item.key as? String ?? item.identifier?.rawValue ?? "").uppercased()
            let isLyrics = item.commonKey == .commonKeyDescription && key.contains("LYRIC")
                || key.contains("LYRIC") || key.contains("USLT") || key.contains("\u{00A9}LYR")
            guard isLyrics, let text = try? await item.load(.stringValue),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            AppLogger.info("Using embedded lyrics tag from \(fileURL.lastPathComponent)", category: .content)
            return text
        }
        return nil
    }

    /// Enhanced-LRC files carry per-word `<mm:ss.xx>` tags inside each line. The
    /// view highlights whole lines, so the word tags are removed rather than
    /// mistaken for lyrics.
    static func stripWordTimestamps(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var depth = 0
        for character in text {
            switch character {
            case "<": depth += 1
            case ">" where depth > 0: depth -= 1
            default: if depth == 0 { out.append(character) }
            }
        }
        return out
    }

    /// Accepts every timestamp shape LRC files use in the wild, and expands a
    /// line carrying several stamps into one line each — rejecting either
    /// silently drops whole verses.
    static func parseLRC(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            var rest = Substring(raw).drop { $0 == " " || $0 == "\t" }
            var stamps: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                guard let stamp = parseTimestamp(String(rest[rest.index(after: rest.startIndex)..<close])) else { break }
                stamps.append(stamp)
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for stamp in stamps {
                lines.append(LyricLine(time: stamp, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// `[mm:ss]`, `[mm:ss.xx]`, `[mm:ss:xx]` and `[hh:mm:ss.xx]` all appear in
    /// files people actually have.
    static func parseTimestamp(_ tag: String) -> TimeInterval? {
        let parts = tag.trimmingCharacters(in: .whitespaces).components(separatedBy: ":")
        let seconds = { (text: String) -> Double? in Double(text.replacingOccurrences(of: ",", with: ".")) }
        switch parts.count {
        case 2:
            guard let minutes = Double(parts[0]), let secs = seconds(parts[1]) else { return nil }
            return minutes * 60 + secs
        case 3:
            guard let first = Double(parts[0]), let second = Double(parts[1]) else { return nil }
            // `mm:ss:xx` uses the third field as hundredths; `hh:mm:ss` does not.
            if parts[2].count <= 2, second < 60, first < 60, parts[0].count <= 2 {
                guard let fraction = Double(parts[2]) else { return nil }
                return first * 60 + second + fraction / 100
            }
            guard let secs = seconds(parts[2]) else { return nil }
            return first * 3600 + second * 60 + secs
        default:
            return nil
        }
    }
}
