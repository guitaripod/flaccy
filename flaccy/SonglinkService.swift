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

    nonisolated private func fetchSonglink(url: URL, title: String, artist: String) async -> SonglinkResult? {
        guard let encodedURL = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let requestURL = URL(string: "https://api.song.link/v1-alpha.1/links?url=\(encodedURL)&userCountry=US&songIfSingle=true")
        else { return nil }

        do {
            let (data, response) = try await session.data(from: requestURL)
            guard let http = response as? HTTPURLResponse else { return nil }

            if http.statusCode == 429 {
                await AppLogger.warning("Songlink rate limited", category: .content)
                return nil
            }

            guard http.statusCode == 200 else {
                await AppLogger.warning("Songlink returned \(http.statusCode)", category: .content)
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pageUrlString = json["pageUrl"] as? String,
                  let pageURL = URL(string: pageUrlString),
                  let linksByPlatform = json["linksByPlatform"] as? [String: [String: Any]]
            else { return nil }

            var platformLinks = [PlatformLink]()
            for (key, platformData) in linksByPlatform {
                guard let urlString = platformData["url"] as? String,
                      let url = URL(string: urlString)
                else { continue }

                if let known = Self.knownPlatforms[key] {
                    platformLinks.append(PlatformLink(
                        key: key,
                        displayName: known.displayName,
                        url: url,
                        iconName: known.iconName,
                        tintColorHex: known.tintColorHex
                    ))
                } else {
                    let displayName = key
                        .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                        .localizedCapitalized
                    platformLinks.append(PlatformLink(
                        key: key,
                        displayName: displayName,
                        url: url,
                        iconName: "link",
                        tintColorHex: 0x8E8E93
                    ))
                }
            }

            platformLinks.sort { a, b in
                let orderA = Self.knownPlatforms[a.key]?.order ?? 100
                let orderB = Self.knownPlatforms[b.key]?.order ?? 100
                return orderA < orderB
            }

            return SonglinkResult(
                pageURL: pageURL,
                platformLinks: platformLinks,
                title: title,
                artist: artist
            )
        } catch {
            await AppLogger.error("Songlink fetch failed: \(error.localizedDescription)", category: .content)
            return nil
        }
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
