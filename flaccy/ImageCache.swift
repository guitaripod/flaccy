import CryptoKit
import UIKit

final class ImageCache {

    static let shared = ImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskCacheURL: URL
    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.midgarcorp.flaccy.imagecache", qos: .utility)

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
    }

    func image(forKey key: String) -> UIImage? {
        let cacheKey = key as NSString
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }

        let filePath = diskPath(forKey: key)
        guard let data = ioQueue.sync(execute: { try? Data(contentsOf: filePath) }),
              let diskImage = UIImage(data: data)
        else {
            return nil
        }

        let cost = estimateCost(of: diskImage)
        memoryCache.setObject(diskImage, forKey: cacheKey, cost: cost)
        return diskImage
    }

    func store(_ image: UIImage, forKey key: String) {
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
        guard let image = UIImage(data: data) else { return }

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

    func imageFromData(_ data: Data?) -> UIImage? {
        guard let data else { return nil }
        return UIImage(data: data)
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

    private func estimateCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
