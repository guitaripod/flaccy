import ImageIO

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Two-tier artwork cache. List and grid cells use the thumbnail tier, decoded
/// straight from the source bytes at a small pixel size via ImageIO so a
/// 3000×3000 embedded FLAC cover never gets fully decoded just to fill a 44pt
/// row. The full tier serves Now Playing and album headers, capped at a size
/// that still fills any screen edge-to-edge.
nonisolated final class AlbumArtworkCache: @unchecked Sendable {

    static let shared = AlbumArtworkCache()

    private static let thumbnailMaxPixelSize: CGFloat = 480
    private static let fullMaxPixelSize: CGFloat = 1600

    private let memoryCache = NSCache<NSString, PlatformImage>()
    private let loadQueue = DispatchQueue(label: "com.midgarcorp.flaccy.artwork", qos: .userInitiated, attributes: .concurrent)
    private var pending = Set<String>()
    private var completionsByKey = [String: [(PlatformImage?) -> Void]]()
    private let pendingLock = NSLock()

    private init() {
        memoryCache.countLimit = 600
        memoryCache.totalCostLimit = 100 * 1024 * 1024
    }

    func artwork(forAlbum title: String, artist: String) -> PlatformImage? {
        memoryCache.object(forKey: cacheKey(title: title, artist: artist, tier: .full) as NSString)
    }

    func thumbnail(forAlbum title: String, artist: String) -> PlatformImage? {
        memoryCache.object(forKey: cacheKey(title: title, artist: artist, tier: .thumbnail) as NSString)
    }

    func loadArtwork(forAlbum title: String, artist: String, completion: @escaping (PlatformImage?) -> Void) {
        load(title: title, artist: artist, tier: .full, completion: completion)
    }

    func loadThumbnail(forAlbum title: String, artist: String, completion: @escaping (PlatformImage?) -> Void) {
        load(title: title, artist: artist, tier: .thumbnail, completion: completion)
    }

    func preloadThumbnail(forAlbum title: String, artist: String) {
        load(title: title, artist: artist, tier: .thumbnail, completion: nil)
    }

    func preloadArtwork(forAlbum title: String, artist: String) {
        load(title: title, artist: artist, tier: .full, completion: nil)
    }

    private enum Tier {
        case thumbnail
        case full

        var maxPixelSize: CGFloat {
            self == .thumbnail ? AlbumArtworkCache.thumbnailMaxPixelSize : AlbumArtworkCache.fullMaxPixelSize
        }
    }

    private func load(title: String, artist: String, tier: Tier, completion: ((PlatformImage?) -> Void)?) {
        let key = cacheKey(title: title, artist: artist, tier: tier)

        if let cached = memoryCache.object(forKey: key as NSString) {
            completion?(cached)
            return
        }

        pendingLock.lock()
        if pending.contains(key) {
            if let completion { completionsByKey[key, default: []].append(completion) }
            pendingLock.unlock()
            return
        }
        pending.insert(key)
        if let completion { completionsByKey[key] = [completion] }
        pendingLock.unlock()

        loadQueue.async { [weak self] in
            guard let self else { return }

            var image: PlatformImage?
            if let data = try? DatabaseManager.shared.fetchAlbumArtwork(title: title, artist: artist) {
                image = Self.decode(data, maxPixelSize: tier.maxPixelSize)
                if let image {
                    self.memoryCache.setObject(image, forKey: key as NSString, cost: image.memoryCost)
                }
            }

            self.pendingLock.lock()
            let callbacks = self.completionsByKey.removeValue(forKey: key) ?? []
            self.pending.remove(key)
            self.pendingLock.unlock()

            guard !callbacks.isEmpty else { return }
            DispatchQueue.main.async {
                for cb in callbacks { cb(image) }
            }
        }
    }

    /// Decodes at most `maxPixelSize` on the longest edge without ever
    /// materializing the full-resolution bitmap, and returns an image that is
    /// already decoded so first display costs nothing on the main thread.
    private static func decode(_ data: Data, maxPixelSize: CGFloat) -> PlatformImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return PlatformImage(data: data)
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return PlatformImage(data: data)
        }
        return PlatformImage(cgImage: cgImage)
    }

    private func cacheKey(title: String, artist: String, tier: Tier) -> String {
        "\(tier == .thumbnail ? "t" : "f")\0\(title)\0\(artist)"
    }
}

nonisolated private extension PlatformImage {
    var memoryCost: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
