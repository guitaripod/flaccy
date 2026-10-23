import ImageIO

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Three-tier artwork cache. List and grid cells use the thumbnail tier, decoded
/// straight from the source bytes at a small pixel size via ImageIO so a
/// 3000×3000 embedded FLAC cover never gets fully decoded just to fill a 44pt
/// row. The now-playing tier feeds the system media panel and palette
/// extraction, and the full tier serves album headers and the artwork editor.
nonisolated final class AlbumArtworkCache: @unchecked Sendable {

    static let shared = AlbumArtworkCache()

    static let didChangeNotification = Notification.Name("AlbumArtworkDidChange")

    private static let thumbnailMaxPixelSize: CGFloat = 480
    private static let nowPlayingMaxPixelSize: CGFloat = 800
    private static let fullMaxPixelSize: CGFloat = 1600

    private let memoryCache = NSCache<NSString, PlatformImage>()
    private let loadQueue = DispatchQueue(label: "com.midgarcorp.flaccy.artwork", qos: .userInitiated, attributes: .concurrent)
    private var pending = Set<String>()
    private var completionsByKey = [String: [(PlatformImage?) -> Void]]()
    private let pendingLock = NSLock()
    private var epoch = 0

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

    func nowPlayingArtwork(forAlbum title: String, artist: String) -> PlatformImage? {
        memoryCache.object(forKey: cacheKey(title: title, artist: artist, tier: .nowPlaying) as NSString)
    }

    func loadArtwork(forAlbum title: String, artist: String, completion: @escaping (PlatformImage?) -> Void) {
        load(title: title, artist: artist, tier: .full, completion: completion)
    }

    func loadNowPlayingArtwork(forAlbum title: String, artist: String, completion: @escaping (PlatformImage?) -> Void) {
        load(title: title, artist: artist, tier: .nowPlaying, completion: completion)
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

    /// Forgets both decoded tiers for each release and tells every surface to
    /// ask again. A decode already in flight when this runs belongs to an older
    /// epoch and is not allowed to put its stale image back.
    func invalidate(keys: [(title: String, artist: String)]) {
        pendingLock.lock()
        epoch += 1
        pendingLock.unlock()
        for key in keys {
            for tier in Tier.allCases {
                memoryCache.removeObject(forKey: cacheKey(title: key.title, artist: key.artist, tier: tier) as NSString)
            }
        }
        if Thread.isMainThread {
            Self.postDidChange()
        } else {
            DispatchQueue.main.async { Self.postDidChange() }
        }
    }

    private static func postDidChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private func currentEpoch() -> Int {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return epoch
    }

    private enum Tier: CaseIterable {
        case thumbnail
        case nowPlaying
        case full

        var maxPixelSize: CGFloat {
            switch self {
            case .thumbnail: AlbumArtworkCache.thumbnailMaxPixelSize
            case .nowPlaying: AlbumArtworkCache.nowPlayingMaxPixelSize
            case .full: AlbumArtworkCache.fullMaxPixelSize
            }
        }

        var cachePrefix: String {
            switch self {
            case .thumbnail: "t"
            case .nowPlaying: "n"
            case .full: "f"
            }
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

            let startedAtEpoch = self.currentEpoch()
            var image: PlatformImage?
            if let data = try? DatabaseManager.shared.fetchAlbumArtwork(title: title, artist: artist) {
                image = Self.decode(data, maxPixelSize: tier.maxPixelSize)
                if let image, startedAtEpoch == self.currentEpoch() {
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
    static func decode(_ data: Data, maxPixelSize: CGFloat) -> PlatformImage? {
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
        "\(tier.cachePrefix)\0\(title)\0\(artist)"
    }
}

nonisolated private extension PlatformImage {
    var memoryCost: Int {
        if let cgImage { return cgImage.bytesPerRow * cgImage.height }
        #if canImport(UIKit)
        let pixels = Int(size.width * scale) * Int(size.height * scale)
        #else
        let pixels = representations.map { $0.pixelsWide * $0.pixelsHigh }.max()
            ?? Int(size.width * size.height)
        #endif
        return max(1, pixels) * 4
    }
}
