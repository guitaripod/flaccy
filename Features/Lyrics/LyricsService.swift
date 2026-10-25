import AVFoundation
import MidgarCore
import Foundation
import FlaccyCore

/// One track's lyrics together with the listener's own timing correction.
nonisolated struct Lyrics: Sendable {
    var document: LyricsDocument
    var offsetMs: Int = 0

    /// The correction in seconds, positive meaning every line comes later.
    var offsetSeconds: Double {
        Double(offsetMs) / 1000
    }

    /// The moment of the song to look up for a playback position: the position
    /// less the correction.
    func songTime(at position: TimeInterval) -> TimeInterval {
        position - offsetSeconds
    }

    /// The sung line at a playback position, for surfaces that show one line.
    func text(at position: TimeInterval) -> String? {
        document.text(at: songTime(at: position))
    }
}

/// Separates "lrclib has nothing for this track" from "we couldn't ask it",
/// and says why we couldn't. A miss is remembered (and expires); a failure is
/// not, so a flaky network leaves a Retry rather than a permanently blank
/// panel.
nonisolated enum LyricsOutcome: Sendable {
    case found(Lyrics)
    case missing
    case failed(LyricsFailure)
}

/// The pure rules behind the lyrics pipeline, kept apart from the service so
/// they run without a database or a network. Mirrors `linux/src/lyrics.rs`.
nonisolated enum LyricsResolution {

    /// The generation of the lyrics pipeline that stores rows. Rows saved
    /// before line ends and word timing existed hold content that a second
    /// look at the server can improve, so they are asked for once more.
    static let revision = 2

    /// How long a remembered miss stands before lrclib is asked again — the
    /// corpus is community-contributed and grows.
    static let missTTL: TimeInterval = 30 * 24 * 3600

    /// Builds the document a stored or fetched answer describes. A Lyricsfile
    /// wins when it reads cleanly and holds synchronized lines; otherwise the
    /// LRC text does.
    static func document(
        synced: String?, plain: String?, lyricsfile: String?, instrumental: Bool
    ) -> LyricsDocument {
        if instrumental { return LyricsDocument(instrumental: true) }
        var document: LyricsDocument
        if let fromFile = lyricsfile.flatMap(LyricsParser.parseLyricsfile), fromFile.hasSynced {
            document = fromFile
        } else if let synced {
            document = LyricsParser.parseLRC(synced)
        } else {
            document = LyricsDocument()
        }
        if document.plain == nil, isFilled(plain) {
            document.plain = plain
        }
        return document
    }

    static func lyrics(from record: LyricsRecord) -> Lyrics {
        Lyrics(
            document: document(
                synced: record.syncedLyrics, plain: record.plainLyrics,
                lyricsfile: record.lyricsfile, instrumental: record.instrumental
            ),
            offsetMs: record.offsetMs
        )
    }

    static func isFilled(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func hasContent(_ record: LyricsRecord) -> Bool {
        record.instrumental
            || isFilled(record.syncedLyrics)
            || isFilled(record.plainLyrics)
            || isFilled(record.lyricsfile)
    }

    /// A row is served as it stands unless it is a miss old enough to ask
    /// again about, or holds content from before the current pipeline
    /// revision. A miss without a timestamp predates the expiry and counts as
    /// old.
    static func isCurrent(_ record: LyricsRecord, now: Date = Date()) -> Bool {
        if hasContent(record) { return record.revision >= revision }
        guard let fetchedAt = record.fetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) <= missTTL
    }

    static func outcome(_ lyrics: Lyrics) -> LyricsOutcome {
        lyrics.document.isEmpty ? .missing : .found(lyrics)
    }

    /// Text with timestamps is synchronized lyrics (word tags and all, so a
    /// timed file keeps its words); anything else is plain.
    static func classify(_ text: String) -> (synced: String?, plain: String?) {
        LyricsParser.parseLRC(text).hasSynced ? (text, nil) : (nil, text)
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
    )

    /// Percent-encodes everything but the unreserved characters, so `&`, `+`
    /// and `=` inside a title never reach the server as syntax.
    static func urlEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }
}

final class LyricsService {

    static let shared = LyricsService()

    private let client = LyricsClient()

    private init() {}

    /// Warms the lyrics cache for a track as soon as it starts, so opening the
    /// lyrics view is instant. A no-op once the track is already cached.
    func prefetch(track: String, artist: String, album: String, fileURL: URL? = nil, duration: TimeInterval = 0) {
        guard !track.isEmpty, !artist.isEmpty else { return }
        let cached = try? DatabaseManager.shared.fetchLyrics(trackTitle: track, artist: artist)
        if let cached, LyricsResolution.isCurrent(cached) { return }
        Task {
            _ = await fetchLyrics(
                track: track, artist: artist, album: album, fileURL: fileURL, duration: duration
            )
        }
    }

    /// Remembers the listener's timing correction for a track's lyrics. A
    /// failure is logged and otherwise ignored: the correction still applies
    /// for as long as the panel is open.
    func saveOffset(track: String, artist: String, offsetMs: Int) {
        do {
            try DatabaseManager.shared.saveLyricsOffset(trackTitle: track, artist: artist, offsetMs: offsetMs)
        } catch {
            MidgarLog.error("Saving lyrics offset failed: \(error.localizedDescription)", category: .content)
        }
    }

    private static let defaultRetryWait: TimeInterval = 0.8
    private static let shortestRetryWait: TimeInterval = 0.3
    private static let longestRetryWait: TimeInterval = 3.0

    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "flaccy/\(version) (https://github.com/guitaripod/flaccy)"
    }

    /// Resolution order: the local database cache, then lyrics the user keeps
    /// alongside the audio (an `.lrc` sidecar or an embedded tag), then lrclib.
    /// A cached answer from an older pipeline revision is shown if the server
    /// cannot improve on it.
    func fetchLyrics(
        track: String, artist: String, album: String,
        fileURL: URL? = nil, duration: TimeInterval = 0
    ) async -> LyricsOutcome {
        let cached = try? DatabaseManager.shared.fetchLyrics(trackTitle: track, artist: artist)
        if let cached, LyricsResolution.isCurrent(cached), LyricsResolution.hasContent(cached) {
            return LyricsResolution.outcome(LyricsResolution.lyrics(from: cached))
        }
        let offsetMs = cached?.offsetMs ?? 0

        if let fileURL, let readable = RemoteStreamCache.shared.readableFile(for: fileURL),
           let local = await Self.readLocalLyrics(at: readable) {
            save(
                track: track, artist: artist, replacing: cached,
                fetched: Fetched(synced: local.synced, plain: local.plain, lyricsfile: nil, instrumental: false)
            )
            return LyricsResolution.outcome(Lyrics(
                document: LyricsResolution.document(
                    synced: local.synced, plain: local.plain, lyricsfile: nil, instrumental: false
                ),
                offsetMs: offsetMs
            ))
        }
        if let cached, LyricsResolution.isCurrent(cached) { return .missing }

        let stale = cached.flatMap { LyricsResolution.hasContent($0) ? $0 : nil }
        switch await lookupRemote(track: track, artist: artist, album: album, duration: duration) {
        case .found(let fetched):
            save(track: track, artist: artist, replacing: cached, fetched: fetched)
            return LyricsResolution.outcome(Lyrics(
                document: LyricsResolution.document(
                    synced: fetched.synced, plain: fetched.plain,
                    lyricsfile: fetched.lyricsfile, instrumental: fetched.instrumental
                ),
                offsetMs: offsetMs
            ))
        case .missing:
            if let stale {
                markCurrent(track: track, artist: artist)
                return LyricsResolution.outcome(LyricsResolution.lyrics(from: stale))
            }
            save(
                track: track, artist: artist, replacing: cached,
                fetched: Fetched(synced: nil, plain: nil, lyricsfile: nil, instrumental: false)
            )
            MidgarLog.info("No lyrics for \(track) — \(artist) (cached miss)", category: .content)
            return .missing
        case .failed(let failure):
            guard let stale else { return .failed(failure) }
            return LyricsResolution.outcome(LyricsResolution.lyrics(from: stale))
        }
    }

    /// Stores what a source answered. The listener's offset rides along from
    /// the row being replaced: a refetch must not undo a correction they made
    /// by ear.
    private func save(track: String, artist: String, replacing existing: LyricsRecord?, fetched: Fetched) {
        let record = LyricsRecord(
            id: existing?.id,
            trackTitle: track,
            artist: artist,
            syncedLyrics: fetched.synced,
            plainLyrics: fetched.plain,
            instrumental: fetched.instrumental,
            fetchedAt: Date(),
            lyricsfile: fetched.lyricsfile,
            offsetMs: existing?.offsetMs ?? 0,
            revision: LyricsResolution.revision
        )
        do {
            try DatabaseManager.shared.saveLyrics(record)
        } catch {
            MidgarLog.error("Saving lyrics failed: \(error.localizedDescription)", category: .content)
        }
    }

    /// Marks a row as current without changing what it holds, for when the
    /// server was asked again and had nothing better.
    private func markCurrent(track: String, artist: String) {
        do {
            try DatabaseManager.shared.setLyricsRevision(
                trackTitle: track, artist: artist, revision: LyricsResolution.revision
            )
        } catch {
            MidgarLog.error("Updating lyrics revision failed: \(error.localizedDescription)", category: .content)
        }
    }

    private struct Fetched {
        let synced: String?
        let plain: String?
        let lyricsfile: String?
        let instrumental: Bool
    }

    private enum Remote {
        case found(Fetched)
        case missing
        case failed(LyricsFailure)
    }

    private enum Reply {
        case body(Data)
        case notFound
        case failed(LyricsFailure)
    }

    /// lrclib's exact-match endpoint is strict about the album name and about
    /// the title as tagged, which are the commonest causes of a false 404. So:
    /// try the full signature, then drop the album, then the title and artist
    /// with edition decoration and featuring credits removed, then the fuzzy
    /// search endpoint, ranking its results here (the endpoint itself is
    /// duration-blind).
    private func lookupRemote(track: String, artist: String, album: String, duration: TimeInterval) async -> Remote {
        let title = LyricsQuery.cleanTitle(track)
        let lead = LyricsQuery.leadArtist(artist)

        var attempts: [(title: String, artist: String, album: String?)] = []
        if !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            attempts.append((track, artist, album))
        }
        attempts.append((track, artist, nil))
        if title != track || lead != artist {
            attempts.append((title, lead, nil))
        }
        for attempt in attempts {
            let result = await getExact(
                title: attempt.title, artist: attempt.artist, album: attempt.album, duration: duration
            )
            if case .missing = result { continue }
            return result
        }
        return await searchFallback(
            track: track, artist: artist, album: album, duration: duration, title: title, lead: lead
        )
    }

    private func getExact(title: String, artist: String, album: String?, duration: TimeInterval) async -> Remote {
        var query = "track_name=\(LyricsResolution.urlEncode(title))&artist_name=\(LyricsResolution.urlEncode(artist))"
        if let album {
            query += "&album_name=\(LyricsResolution.urlEncode(album))"
        }
        if duration > 0 {
            query += "&duration=\(Int(duration.rounded()))"
        }
        switch await request(path: "/api/get", query: query) {
        case .body(let body): return Self.parseRecord(body)
        case .notFound: return .missing
        case .failed(let failure): return .failed(failure)
        }
    }

    private func searchFallback(
        track: String, artist: String, album: String, duration: TimeInterval,
        title: String, lead: String
    ) async -> Remote {
        let query = "track_name=\(LyricsResolution.urlEncode(title))&artist_name=\(LyricsResolution.urlEncode(lead))"
        let body: Data
        switch await request(path: "/api/search", query: query) {
        case .body(let data): body = data
        case .notFound: return .missing
        case .failed(let failure): return .failed(failure)
        }
        guard let items = try? JSONSerialization.jsonObject(with: body) as? [Any] else { return .missing }
        let records = items.map { $0 as? [String: Any] ?? [:] }
        let candidates = records.map { record in
            LyricsCandidate(
                title: LyricsQuery.cleanTitle(record["trackName"] as? String ?? ""),
                artist: LyricsQuery.leadArtist(record["artistName"] as? String ?? ""),
                album: record["albumName"] as? String ?? "",
                duration: record["duration"] as? Double ?? 0,
                hasSynced: LyricsResolution.isFilled(record["syncedLyrics"] as? String),
                hasWordSync: record["hasWordSync"] as? Bool ?? false
            )
        }
        let wanted = LyricsWanted(title: title, artist: lead, album: album, duration: duration)
        guard let best = LyricsScoring.bestCandidate(wanted, candidates) else { return .missing }
        MidgarLog.info(
            "lrclib search matched \(track) — \(artist) (score \(String(format: "%.2f", best.score)))",
            category: .content
        )
        return Self.record(from: records[best.index])
    }

    /// One GET, retried once when the server is overloaded or throttling,
    /// waiting as long as it asks within reason. A 404 is an answer, not a
    /// failure.
    private func request(path: String, query: String) async -> Reply {
        guard let url = URL(string: "https://lrclib.net\(path)?\(query)") else { return .failed(.rejected(400)) }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        var lastFailure = LyricsFailure.unreachable
        for attempt in 0..<2 {
            do {
                let (data, response) = try await client.data(for: urlRequest)
                guard let http = response as? HTTPURLResponse else { return .failed(.unreachable) }
                switch http.statusCode {
                case 200..<300:
                    return .body(data)
                case 404:
                    return .notFound
                case let code where attempt == 0 && (code == 429 || code >= 500):
                    lastFailure = .forStatus(code)
                    try await Task.sleep(for: .seconds(Self.retryWait(for: http)))
                default:
                    MidgarLog.error("Lyrics request failed: HTTP \(http.statusCode)", category: .content)
                    return .failed(.forStatus(http.statusCode))
                }
            } catch {
                MidgarLog.error("Lyrics request failed: \(error.localizedDescription)", category: .content)
                return .failed(Self.failure(of: error))
            }
        }
        return .failed(lastFailure)
    }

    private static func failure(of error: Error) -> LyricsFailure {
        (error as? URLError)?.code == .timedOut ? .timedOut : .unreachable
    }

    private static func retryWait(for response: HTTPURLResponse) -> TimeInterval {
        let asked = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return min(max(asked ?? defaultRetryWait, shortestRetryWait), longestRetryWait)
    }

    private static func parseRecord(_ body: Data) -> Remote {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return .missing }
        return record(from: json)
    }

    private static func record(from json: [String: Any]) -> Remote {
        func text(_ key: String) -> String? {
            let value = json[key] as? String
            return LyricsResolution.isFilled(value) ? value : nil
        }
        let fetched = Fetched(
            synced: text("syncedLyrics"),
            plain: text("plainLyrics"),
            lyricsfile: text("lyricsfile"),
            instrumental: json["instrumental"] as? Bool ?? false
        )
        if fetched.synced == nil, fetched.plain == nil, !fetched.instrumental { return .missing }
        return .found(fetched)
    }

    private struct LocalLyrics {
        let synced: String?
        let plain: String?
    }

    /// Lyrics the user curated themselves, in the order other players look: an
    /// `.lrc`/`.elrc` sidecar next to the audio, then the file's own tags. Never
    /// written back — the library is the user's.
    private static func readLocalLyrics(at fileURL: URL) async -> LocalLyrics? {
        for ext in ["lrc", "elrc"] {
            let sidecar = fileURL.deletingPathExtension().appendingPathExtension(ext)
            if let text = try? String(contentsOf: sidecar, encoding: .utf8),
               LyricsResolution.isFilled(text) {
                MidgarLog.info("Using lyrics sidecar \(sidecar.lastPathComponent)", category: .content)
                return classify(text)
            }
        }
        if let tagged = await taggedLyrics(at: fileURL) { return classify(tagged) }
        return nil
    }

    private static func classify(_ text: String) -> LocalLyrics {
        let classified = LyricsResolution.classify(text)
        return LocalLyrics(synced: classified.synced, plain: classified.plain)
    }

    private static func taggedLyrics(at fileURL: URL) async -> String? {
        let asset = AVURLAsset(url: fileURL)
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        for item in metadata {
            let key = (item.key as? String ?? item.identifier?.rawValue ?? "").uppercased()
            let isLyrics = item.commonKey == .commonKeyDescription && key.contains("LYRIC")
                || key.contains("LYRIC") || key.contains("USLT") || key.contains("\u{00A9}LYR")
            guard isLyrics, let text = try? await item.load(.stringValue),
                  LyricsResolution.isFilled(text) else { continue }
            MidgarLog.info("Using embedded lyrics tag from \(fileURL.lastPathComponent)", category: .content)
            return text
        }
        return nil
    }
}
