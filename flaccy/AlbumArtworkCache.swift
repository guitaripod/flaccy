import UIKit

final class AlbumArtworkCache {

    static let shared = AlbumArtworkCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let loadQueue = DispatchQueue(label: "com.midgarcorp.flaccy.artwork", qos: .userInitiated, attributes: .concurrent)
    private var pending = Set<String>()
    private var completionsByKey = [String: [(UIImage?) -> Void]]()
    private let pendingLock = NSLock()

    private init() {
        memoryCache.countLimit = 300
    }

    func artwork(forAlbum title: String, artist: String) -> UIImage? {
        let key = cacheKey(title: title, artist: artist)
        return memoryCache.object(forKey: key as NSString)
    }

    func loadArtwork(forAlbum title: String, artist: String, completion: @escaping (UIImage?) -> Void) {
        let key = cacheKey(title: title, artist: artist)

        if let cached = memoryCache.object(forKey: key as NSString) {
            completion(cached)
            return
        }

        pendingLock.lock()
        let alreadyPending = pending.contains(key)
        if !alreadyPending { pending.insert(key) }
        if alreadyPending {
            completionsByKey[key, default: []].append(completion)
            pendingLock.unlock()
            return
        }
        completionsByKey[key] = [completion]
        pendingLock.unlock()

        loadQueue.async { [weak self] in
            guard let self else { return }

            let image: UIImage?
            if let data = try? DatabaseManager.shared.fetchAlbumArtwork(title: title, artist: artist) {
                image = UIImage(data: data)
                if let image { self.memoryCache.setObject(image, forKey: key as NSString) }
            } else {
                image = nil
            }

            self.pendingLock.lock()
            let callbacks = self.completionsByKey.removeValue(forKey: key) ?? []
            self.pending.remove(key)
            self.pendingLock.unlock()

            DispatchQueue.main.async {
                for cb in callbacks { cb(image) }
            }
        }
    }

    func preloadArtwork(forAlbum title: String, artist: String) {
        let key = cacheKey(title: title, artist: artist)
        if memoryCache.object(forKey: key as NSString) != nil { return }

        pendingLock.lock()
        let alreadyPending = pending.contains(key)
        if !alreadyPending { pending.insert(key) }
        pendingLock.unlock()

        if alreadyPending { return }

        loadQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.pendingLock.lock()
                self.pending.remove(key)
                self.pendingLock.unlock()
            }

            guard let data = try? DatabaseManager.shared.fetchAlbumArtwork(title: title, artist: artist),
                  let image = UIImage(data: data) else { return }

            self.memoryCache.setObject(image, forKey: key as NSString)
        }
    }

    private func cacheKey(title: String, artist: String) -> String {
        "\(title)\0\(artist)"
    }
}
