import UIKit

/// Resolves a representative artist photo with the chain: memory/disk cache →
/// Apple Music catalog artwork → Last.fm artist image (rejecting the star
/// placeholder) → nil, remembering misses so tracks by the same artist don't
/// re-query the network.
final class ArtistImageService {

    static let shared = ArtistImageService()

    private let missCache = NSCache<NSString, NSDate>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    nonisolated private static let lastFMPlaceholderHash = "2a96cbd8b46e442fc41c2b86b821562f"
    private static let missTTL: TimeInterval = 60 * 30

    nonisolated private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private init() {
        missCache.countLimit = 300
    }

    func image(for artist: String) async -> UIImage? {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = cacheKey(for: trimmed)

        if let cached = ImageCache.shared.image(forKey: key) {
            return cached
        }
        if let miss = missCache.object(forKey: key as NSString),
           Date().timeIntervalSince(miss as Date) < Self.missTTL {
            return nil
        }
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task { await Self.resolve(artist: trimmed) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image {
            ImageCache.shared.store(image, forKey: key)
        } else {
            missCache.setObject(NSDate(), forKey: key as NSString)
        }
        return image
    }

    private func cacheKey(for artist: String) -> String {
        "artist-photo|\(artist.lowercased())"
    }

    nonisolated private static func resolve(artist: String) async -> UIImage? {
        if let data = await MusicKitService.shared.fetchArtistImage(artist: artist),
           let image = UIImage(data: data) {
            await AppLogger.debug("Artist photo from Apple Music for \(artist)", category: .content)
            return image
        }
        if let image = await fetchLastFMImage(artist: artist) {
            await AppLogger.debug("Artist photo from Last.fm for \(artist)", category: .content)
            return image
        }
        await AppLogger.debug("No artist photo found for \(artist)", category: .content)
        return nil
    }

    nonisolated private static func fetchLastFMImage(artist: String) async -> UIImage? {
        guard let info = await LastFMService.shared.fetchArtistInfo(artist: artist),
              let urlString = info.imageURL,
              !isPlaceholder(urlString),
              let url = URL(string: urlString)
        else { return nil }

        do {
            let (data, response) = try await downloadSession.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = UIImage(data: data)
            else { return nil }
            return image
        } catch {
            await AppLogger.error("Last.fm artist image download failed: \(error.localizedDescription)", category: .content)
            return nil
        }
    }

    /// Last.fm serves a generic white-star image for artists without real
    /// photos; its URL always carries this content hash.
    nonisolated private static func isPlaceholder(_ urlString: String) -> Bool {
        urlString.contains(lastFMPlaceholderHash)
    }
}
