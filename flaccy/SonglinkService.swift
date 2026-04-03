import Foundation

nonisolated enum SonglinkPlatform: String, CaseIterable, Sendable {
    case spotify
    case appleMusic
    case youtubeMusic
    case youtube
    case tidal
    case amazonMusic
    case deezer
    case soundcloud

    var displayName: String {
        switch self {
        case .spotify: "Spotify"
        case .appleMusic: "Apple Music"
        case .youtubeMusic: "YouTube Music"
        case .youtube: "YouTube"
        case .tidal: "Tidal"
        case .amazonMusic: "Amazon Music"
        case .deezer: "Deezer"
        case .soundcloud: "SoundCloud"
        }
    }

    var iconName: String {
        switch self {
        case .spotify: "waveform"
        case .appleMusic: "music.note"
        case .youtubeMusic: "play.rectangle.fill"
        case .youtube: "play.rectangle"
        case .tidal: "waveform.circle"
        case .amazonMusic: "headphones"
        case .deezer: "beats.headphones"
        case .soundcloud: "cloud"
        }
    }

    var tintColorHex: UInt {
        switch self {
        case .spotify: 0x1DB954
        case .appleMusic: 0xFC3C44
        case .youtubeMusic: 0xFF0000
        case .youtube: 0xFF0000
        case .tidal: 0x000000
        case .amazonMusic: 0x25D1DA
        case .deezer: 0xA238FF
        case .soundcloud: 0xFF5500
        }
    }
}

nonisolated struct SonglinkResult: Sendable {
    let pageURL: URL
    let platformLinks: [SonglinkPlatform: URL]
    let title: String
    let artist: String
}

final class SonglinkService {

    static let shared = SonglinkService()

    private let session: URLSession
    private let throttle = SonglinkThrottle()
    private let cache = NSCache<NSString, CachedResult>()

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

        await throttle.wait()

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

            var platformLinks = [SonglinkPlatform: URL]()
            for platform in SonglinkPlatform.allCases {
                if let platformData = linksByPlatform[platform.rawValue],
                   let urlString = platformData["url"] as? String,
                   let url = URL(string: urlString) {
                    platformLinks[platform] = url
                }
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

    func wait() async {
        let elapsed = Date().timeIntervalSince(lastRequest)
        if elapsed < 6.0 {
            try? await Task.sleep(for: .milliseconds(Int((6.0 - elapsed) * 1000)))
        }
        lastRequest = Date()
    }
}
