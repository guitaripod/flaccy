import Foundation

nonisolated struct PlatformLink: Sendable, Hashable {
    let key: String
    let displayName: String
    let url: URL
    let iconName: String
    let tintColorHex: UInt

    static func == (lhs: PlatformLink, rhs: PlatformLink) -> Bool {
        lhs.key == rhs.key
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }
}

nonisolated struct SonglinkResult: Sendable {
    let pageURL: URL
    let platformLinks: [PlatformLink]
    let title: String
    let artist: String
}

final class SonglinkService {

    static let shared = SonglinkService()

    private let session: URLSession
    private let throttle = SonglinkThrottle()
    private let cache = NSCache<NSString, CachedResult>()

    private static let knownPlatforms: [String: (displayName: String, iconName: String, tintColorHex: UInt, order: Int)] = [
        "spotify": ("Spotify", "waveform", 0x1DB954, 0),
        "appleMusic": ("Apple Music", "music.note", 0xFC3C44, 1),
        "youtubeMusic": ("YouTube Music", "play.rectangle.fill", 0xFF0000, 2),
        "youtube": ("YouTube", "play.rectangle", 0xFF0000, 3),
        "tidal": ("Tidal", "waveform.circle", 0x000000, 4),
        "amazonMusic": ("Amazon Music", "headphones", 0x25D1DA, 5),
        "deezer": ("Deezer", "beats.headphones", 0xA238FF, 6),
        "soundcloud": ("SoundCloud", "cloud", 0xFF5500, 7),
        "pandora": ("Pandora", "radio", 0x224099, 8),
        "napster": ("Napster", "opticaldisc", 0x0168DA, 9),
        "audiomack": ("Audiomack", "waveform.badge.plus", 0xFFA500, 10),
        "anghami": ("Anghami", "music.mic", 0x6200EA, 11),
        "boomplay": ("Boomplay", "music.note.tv", 0xE44C4B, 12),
        "itunes": ("iTunes", "music.note.house", 0xFC3C44, 13),
        "yandex": ("Yandex Music", "globe", 0xFFCC00, 14),
        "spinrilla": ("Spinrilla", "dot.radiowaves.right", 0x1A1A2E, 15),
        "audius": ("Audius", "waveform.path", 0xCC0FE0, 16),
        "line": ("LINE Music", "ellipsis.bubble", 0x06C755, 17),
    ]

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
        cache.countLimit = 100
    }

    nonisolated func lookup(title: String, artist: String) async -> SonglinkResult? {
        let cacheKey = "song|\(artist.lowercased())|\(title.lowercased())" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached.result
        }

        guard let songMatch = await MusicKitService.shared.findSong(title: title, artist: artist) else {
            await AppLogger.debug("Songlink: no Apple Music match for \(artist) - \(title)", category: .content)
            return nil
        }

        guard !Task.isCancelled else { return nil }
        await throttle.wait()
        guard !Task.isCancelled else { return nil }

        guard let result = await fetchSonglink(url: songMatch.appleMusicURL, title: title, artist: artist) else {
            return nil
        }

        cache.setObject(CachedResult(result: result), forKey: cacheKey)
        return result
    }

    nonisolated func lookupAlbum(title: String, artist: String) async -> SonglinkResult? {
        let cacheKey = "album|\(artist.lowercased())|\(title.lowercased())" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached.result
        }

        guard let albumMatch = await MusicKitService.shared.findAlbum(title: title, artist: artist) else {
            await AppLogger.debug("Songlink: no Apple Music album match for \(artist) - \(title)", category: .content)
            return nil
        }

        await throttle.wait()

        guard let result = await fetchSonglink(url: albumMatch.appleMusicURL, title: title, artist: artist) else {
            return nil
        }

        cache.setObject(CachedResult(result: result), forKey: cacheKey)
        return result
    }

    /// Odesli retired its public API (every call now answers 401
    /// `PUBLIC_API_ACCESS_DEPRECATED`), so the song.link page itself is the
    /// source: `song.link/i/<iTunes id>` and `album.link/i/<collection id>`
    /// resolve directly, and the page embeds its platform links as Next.js
    /// data. A page that cannot be parsed still yields the universal link.
    nonisolated private func fetchSonglink(url: URL, title: String, artist: String) async -> SonglinkResult? {
        guard let pageURL = SonglinkPage.pageURL(forAppleMusic: url) else {
            await AppLogger.warning("Songlink: no iTunes id in \(url.absoluteString)", category: .content)
            return nil
        }
        var request = URLRequest(url: pageURL)
        request.setValue("Mozilla/5.0 (compatible; Flaccy)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 429 {
                await AppLogger.warning("Songlink rate limited", category: .content)
                return nil
            }
            guard http.statusCode == 200 else {
                await AppLogger.warning("Songlink page returned \(http.statusCode)", category: .content)
                return nil
            }
            let parsed = SonglinkPage.parse(html: String(decoding: data, as: UTF8.self))
            let links = parsed.links.map { platformLink(key: $0.platform, url: $0.url) }
                .sorted { a, b in
                    (Self.knownPlatforms[a.key]?.order ?? 100) < (Self.knownPlatforms[b.key]?.order ?? 100)
                }
            return SonglinkResult(
                pageURL: parsed.pageURL ?? pageURL,
                platformLinks: links,
                title: parsed.title ?? title,
                artist: parsed.artist ?? artist
            )
        } catch {
            await AppLogger.error("Songlink fetch failed: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    nonisolated private func platformLink(key: String, url: URL) -> PlatformLink {
        if let known = Self.knownPlatforms[key] {
            return PlatformLink(
                key: key, displayName: known.displayName, url: url,
                iconName: known.iconName, tintColorHex: known.tintColorHex
            )
        }
        let displayName = key
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .localizedCapitalized
        return PlatformLink(key: key, displayName: displayName, url: url, iconName: "link", tintColorHex: 0x8E8E93)
    }
}

/// The song.link page contract, mirrored in Rust as `linux/src/songlink.rs`:
/// the universal URL is derived from the iTunes id, and the platform links
/// live in the page's `__NEXT_DATA__` under `pageData.sections[].links[]`.
nonisolated enum SonglinkPage {

    struct Link: Sendable, Equatable {
        let platform: String
        let url: URL
    }

    struct Parsed: Sendable {
        let pageURL: URL?
        let title: String?
        let artist: String?
        let links: [Link]
    }

    /// A song URL carries the track id as `?i=`; an album URL ends in the
    /// collection id. Anything else has no song.link shortcut.
    static func pageURL(forAppleMusic url: URL) -> URL? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let track = components?.queryItems?.first(where: { $0.name == "i" })?.value, isNumeric(track) {
            return URL(string: "https://song.link/i/\(track)")
        }
        let collection = url.lastPathComponent
        guard isNumeric(collection) else { return nil }
        return URL(string: "https://album.link/i/\(collection)")
    }

    static func parse(html: String) -> Parsed {
        let empty = Parsed(pageURL: nil, title: nil, artist: nil, links: [])
        guard let open = html.range(of: "<script id=\"__NEXT_DATA__\" type=\"application/json\">"),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex),
              let json = try? JSONSerialization.jsonObject(with: Data(html[open.upperBound..<close.lowerBound].utf8)) as? [String: Any],
              let pageData = ((json["props"] as? [String: Any])?["pageProps"] as? [String: Any])?["pageData"] as? [String: Any]
        else { return empty }
        let entity = pageData["entityData"] as? [String: Any]
        var seen = Set<String>()
        var links = [Link]()
        for section in pageData["sections"] as? [[String: Any]] ?? [] {
            for raw in section["links"] as? [[String: Any]] ?? [] {
                guard let platform = raw["platform"] as? String,
                      let urlString = raw["url"] as? String,
                      let url = URL(string: urlString),
                      seen.insert(platform).inserted
                else { continue }
                links.append(Link(platform: platform, url: url))
            }
        }
        return Parsed(
            pageURL: (pageData["pageUrl"] as? String).flatMap(URL.init(string:)),
            title: entity?["title"] as? String,
            artist: entity?["artistName"] as? String,
            links: links
        )
    }

    private static func isNumeric(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy(\.isNumber)
    }
}

private final class CachedResult: NSObject {
    let result: SonglinkResult
    init(result: SonglinkResult) { self.result = result }
}

private actor SonglinkThrottle {
    private var lastRequest: Date = .distantPast
    private let interval: TimeInterval = 6.0

    /// Reserves the next request slot before suspending so concurrent waiters
    /// serialize at `interval` spacing despite actor reentrancy.
    func wait() async {
        let target = max(Date(), lastRequest.addingTimeInterval(interval))
        lastRequest = target
        let delay = target.timeIntervalSinceNow
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
    }
}
