import AppKit

/// AppKit port of the iOS ArtistImageService: memory/disk cache → Apple Music
/// catalog artwork → Last.fm artist image (rejecting the star placeholder) →
/// nil, remembering misses so repeat lookups stay off the network.
final class MacArtistImageService {

    static let shared = MacArtistImageService()

    private let missCache = NSCache<NSString, NSDate>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

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

    func image(for artist: String) async -> NSImage? {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let key = "artist-photo|\(trimmed.lowercased())"

        if let cached = await ImageCache.shared.loadImage(forKey: key) {
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

    nonisolated private static func resolve(artist: String) async -> NSImage? {
        if let data = await MusicKitService.shared.fetchArtistImage(artist: artist),
           let image = NSImage(data: data) {
            return image
        }
        return await fetchLastFMImage(artist: artist)
    }

    nonisolated private static func fetchLastFMImage(artist: String) async -> NSImage? {
        guard let info = await LastFMService.shared.fetchArtistInfo(artist: artist),
              let urlString = info.imageURL,
              !urlString.contains(lastFMPlaceholderHash),
              let url = URL(string: urlString)
        else { return nil }

        do {
            let (data, response) = try await downloadSession.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data)
            else { return nil }
            return image
        } catch {
            await AppLogger.error("Artist image download failed: \(error.localizedDescription)", category: .content)
            return nil
        }
    }
}
