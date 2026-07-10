import CryptoKit

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

final class ImageCache {

    static let shared = ImageCache()

    nonisolated private static let maxDiskCacheBytes = 100 * 1024 * 1024
    nonisolated private static let maxDiskCacheAge: TimeInterval = 90 * 24 * 60 * 60

    private let memoryCache = NSCache<NSString, PlatformImage>()
    private let diskCacheURL: URL
    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.midgarcorp.flaccy.imagecache", qos: .utility)
    private let readQueue = DispatchQueue(
        label: "com.midgarcorp.flaccy.imagecache.read",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {
        memoryCache.totalCostLimit = 50 * 1024 * 1024

        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskCacheURL = caches.appendingPathComponent("flaccy-images", isDirectory: true)

        if !fileManager.fileExists(atPath: diskCacheURL.path) {
            do {
                try fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
            } catch {
                AppLogger.error("Failed to create image cache directory: \(error.localizedDescription)", category: .content)
            }
        }

        let cacheDirectory = diskCacheURL
        ioQueue.async {
            Self.pruneDiskCache(at: cacheDirectory)
        }
    }

    func image(forKey key: String) -> PlatformImage? {
        let cacheKey = key as NSString
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        let filePath = diskPath(forKey: key)
        guard let data = try? Data(contentsOf: filePath),
              let diskImage = PlatformImage(data: data)
        else {
            return nil
        }

        let cost = estimateCost(of: diskImage)
        memoryCache.setObject(diskImage, forKey: cacheKey, cost: cost)
        touchDiskFile(filePath)
        return diskImage
    }

    /// Off-main variant of `image(forKey:)`: on a memory miss, performs the disk read,
    /// decode, and `preparingForDisplay()` on a background queue so main-actor callers
    /// never block on I/O or contend with pending compression writes.
    func loadImage(forKey key: String) async -> PlatformImage? {
        let cacheKey = key as NSString
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        let filePath = diskPath(forKey: key)
        let diskImage = await withCheckedContinuation { (continuation: CheckedContinuation<PlatformImage?, Never>) in
            readQueue.async {
                guard let data = try? Data(contentsOf: filePath),
                      let image = PlatformImage(data: data)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image.preparingForDisplay() ?? image)
            }
        }

        guard let diskImage else { return nil }
        let cost = estimateCost(of: diskImage)
        memoryCache.setObject(diskImage, forKey: cacheKey, cost: cost)
        touchDiskFile(filePath)
        return diskImage
    }

    /// Refreshes the file's modification date on a disk-cache hit so the
    /// age-based prune measures real use instead of the original write time —
    /// otherwise images displayed daily still expire at the 90-day mark.
    private func touchDiskFile(_ url: URL) {
        ioQueue.async {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: url.path
            )
        }
    }

    func store(_ image: PlatformImage, forKey key: String) {
        let cost = estimateCost(of: image)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        let filePath = diskPath(forKey: key)
        ioQueue.async { [fileManager] in
            guard let data = image.jpegData(compressionQuality: 0.85) else { return }
            do {
                try data.write(to: filePath, options: .atomic)
            } catch {
                Task { @MainActor in
                    AppLogger.error("Failed to write image to disk: \(error.localizedDescription)", category: .content)
                }
                if !fileManager.fileExists(atPath: filePath.deletingLastPathComponent().path) {
                    try? fileManager.createDirectory(
                        at: filePath.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? data.write(to: filePath, options: .atomic)
                }
            }
        }
    }

    func store(data: Data, forKey key: String) {
        guard let image = PlatformImage(data: data) else { return }

        let cost = estimateCost(of: image)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        let filePath = diskPath(forKey: key)
        ioQueue.async {
            do {
                try data.write(to: filePath, options: .atomic)
            } catch {
                Task { @MainActor in
                    AppLogger.error("Failed to write image data to disk: \(error.localizedDescription)", category: .content)
                }
            }
        }
    }

    func imageFromData(_ data: Data?) -> PlatformImage? {
        guard let data else { return nil }
        return PlatformImage(data: data)
    }

    private func diskPath(forKey key: String) -> URL {
        let hash = md5Hash(key)
        return diskCacheURL.appendingPathComponent(hash)
    }

    private func md5Hash(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    private func estimateCost(of image: PlatformImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// Bounds the disk tier once per launch: evicts least-recently-used files until the
    /// directory fits within `maxDiskCacheBytes`, and drops anything untouched for
    /// longer than `maxDiskCacheAge`.
    private nonisolated static func pruneDiskCache(at directory: URL) {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .contentAccessDateKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: .skipsHiddenFiles
        ) else { return }

        let now = Date()
        let entries = files
            .compactMap { url -> (url: URL, size: Int, lastUsed: Date)? in
                guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                let lastUsed = max(
                    values.contentAccessDate ?? .distantPast,
                    values.contentModificationDate ?? .distantPast
                )
                return (url, values.fileSize ?? 0, lastUsed)
            }
            .sorted { $0.lastUsed < $1.lastUsed }

        var totalSize = entries.reduce(0) { $0 + $1.size }
        var removedCount = 0
        for entry in entries {
            let expired = now.timeIntervalSince(entry.lastUsed) > maxDiskCacheAge
            guard totalSize > maxDiskCacheBytes || expired else { break }
            do {
                try fileManager.removeItem(at: entry.url)
                totalSize -= entry.size
                removedCount += 1
            } catch {
                Task { @MainActor in
                    AppLogger.error("Failed to prune image cache file: \(error.localizedDescription)", category: .content)
                }
            }
        }

        if removedCount > 0 {
            let summary = "Pruned \(removedCount) image cache files, \(totalSize) bytes remain"
            Task { @MainActor in
                AppLogger.info(summary, category: .content)
            }
        }
    }
}
