import ImageIO
import MidgarCore
import UIKit

/// Resolves cover-art URLs for scrobble-derived chart entries that are absent from
/// the local library, via Last.fm's `album.getInfo` / `track.getInfo`. Results
/// (including misses) are memoised in-memory and keyed by album/track+artist so a
/// given entry hits the network at most once, and concurrent cells for the same
/// entry share a single in-flight request.
actor RecapRemoteArtworkResolver {
    static let shared = RecapRemoteArtworkResolver()

    var cache: [String: String?] = [:]
    var inFlight: [String: Task<String?, Never>] = [:]

    func resolvedURL(for query: RecapArtworkQuery) async -> String? {
        let key = query.cacheKey
        if let cached = cache[key] {
            MidgarLog.debug("Recap remote art cache hit \(key) -> \(cached ?? "nil")", category: .content)
            return cached
        }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<String?, Never> { await Self.fetch(query) }
        inFlight[key] = task
        let url = await task.value
        inFlight[key] = nil
        cache[key] = url
        MidgarLog.debug("Recap remote art resolved \(key) -> \(url ?? "miss")", category: .content)
        return url
    }

    static func fetch(_ query: RecapArtworkQuery) async -> String? {
        switch query {
        case let .album(artist, album):
            return await LastFMService.shared.fetchAlbumInfo(artist: artist, album: album)?.imageURL
        case let .track(artist, track):
            guard let info = await LastFMService.shared.fetchTrackInfo(artist: artist, track: track),
                  let album = info.album, !album.isEmpty else { return nil }
            return await LastFMService.shared.fetchAlbumInfo(artist: info.artist, album: album)?.imageURL
        }
    }
}

/// A UIImageView that loads local album art (via AlbumArtworkCache) or a remote
/// URL (via ImageCache), guarding against cell reuse with a per-request token.
///
/// While a real image is still being fetched it shows an animated shimmer so the
/// placeholder reads as a skeleton rather than a flat box; the shimmer clears the
/// moment the artwork lands (or, on a miss, reveals the SF Symbol placeholder).
///
/// All decoding and downsampling happens off the main thread; the decoded
/// thumbnails are cached so scrolling never pays a synchronous decode cost.
final class AsyncImageView: UIImageView {

    nonisolated static let maxPixelSize: CGFloat = 600

    /// `NSCache` does its own locking, so the thumbnail cache can be read and filled from the decode queue and the main thread.
    nonisolated(unsafe) static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 256
        return cache
    }()

    /// Records entries that provably have no artwork (no local art, no remote URL,
    /// or a failed download) so a reconfigured cell shows its placeholder instantly
    /// instead of kicking off the same doomed lookup on every scroll pass.
    nonisolated(unsafe) static let negativeCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 512
        return cache
    }()

    nonisolated static func markMiss(_ key: String) {
        negativeCache.setObject(NSNumber(value: true), forKey: key as NSString)
    }

    nonisolated static func albumKey(title: String, artist: String) -> String {
        "album:\(title)\u{0}\(artist)"
    }

    nonisolated static let decodeQueue = DispatchQueue(
        label: "com.midgarcorp.flaccy.recap.decode",
        qos: .userInitiated,
        attributes: .concurrent
    )

    var token = UUID()
    let shimmerLayer = CAGradientLayer()
    var isShimmering = false

    convenience init() { self.init(frame: .zero) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        backgroundColor = UIColor.white.withAlphaComponent(0.06)
        configureShimmerLayer()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        shimmerLayer.frame = bounds
    }

    /// Loads a remote image. Reads the shared thumbnail cache synchronously first —
    /// so a prewarmed or previously-loaded URL sets immediately with no placeholder
    /// flash, no re-download, and no token churn on reconfigure — and only falls to
    /// the async download for a genuine cache miss. `alsoCache` mirrors the result
    /// into a second key (an album key) so an album that resolved via a remote URL
    /// is later found by its synchronous album-key read.
    func setRemote(_ urlString: String?, placeholder: UIImage?, alsoCache extraKey: String? = nil) {
        guard let urlString, let url = URL(string: urlString) else {
            token = UUID(); setPlaceholder(placeholder); endShimmer(); return
        }
        let thumbKey = "remote:\(urlString)"
        if let thumb = Self.thumbnailCache.object(forKey: thumbKey as NSString) {
            token = UUID()
            if let extraKey { Self.thumbnailCache.setObject(thumb, forKey: extraKey as NSString) }
            setImageIfChanged(thumb)
            endShimmer()
            return
        }
        if Self.negativeCache.object(forKey: thumbKey as NSString) != nil {
            token = UUID(); setPlaceholder(placeholder); endShimmer(); return
        }

        let current = UUID()
        token = current
        setPlaceholder(placeholder)
        beginShimmer()
        let keys = extraKey.map { [thumbKey, $0] } ?? [thumbKey]
        Self.decodeQueue.async { [weak self] in
            guard let self else { return }
            if let cached = ImageCache.shared.image(forKey: urlString), let thumb = Self.prepared(cached) {
                self.deliver(thumb, keys: keys, token: current)
                return
            }
            RemoteImageClient().load(from: url) { [weak self] data in
                guard let self else { return }
                guard let data, let thumb = Self.downsampled(from: data) else {
                    Self.markMiss(thumbKey)
                    self.finishShimmer(token: current)
                    return
                }
                ImageCache.shared.store(data: data, forKey: urlString)
                self.deliver(thumb, keys: keys, token: current)
            }
        }
    }

    /// Loads cover art, preferring the local library, then any supplied remote URL,
    /// then a lazy Last.fm lookup (`remoteFallback`) for non-local entries, before
    /// finally settling on the SF Symbol placeholder.
    /// Loads cover art, preferring the local library, then any supplied remote URL,
    /// then a lazy Last.fm lookup (`remoteFallback`) for non-local entries, before
    /// finally settling on the SF Symbol placeholder.
    ///
    /// Reads the shared thumbnail cache synchronously first: once the artwork has
    /// been prewarmed (or previously loaded) this sets the image immediately with no
    /// placeholder flash and no async work, and a known-miss shows the placeholder
    /// at once. The async resolve path runs only for a genuine cache miss.
    func setAlbum(title: String, artist: String, remoteURL: String?, placeholder: UIImage?, remoteFallback: RecapArtworkQuery? = nil) {
        let thumbKey = Self.albumKey(title: title, artist: artist)
        if let thumb = Self.thumbnailCache.object(forKey: thumbKey as NSString) {
            token = UUID()
            setImageIfChanged(thumb)
            endShimmer()
            return
        }
        if Self.negativeCache.object(forKey: thumbKey as NSString) != nil {
            token = UUID(); setPlaceholder(placeholder); endShimmer(); return
        }

        let current = UUID()
        token = current
        setPlaceholder(placeholder)
        beginShimmer()
        if let cached = AlbumArtworkCache.shared.thumbnail(forAlbum: title, artist: artist) {
            Self.decodeQueue.async { [weak self] in
                guard let self, let thumb = Self.prepared(cached) else { return }
                self.deliver(thumb, keys: [thumbKey], token: current)
            }
            return
        }

        AlbumArtworkCache.shared.loadThumbnail(forAlbum: title, artist: artist) { [weak self] image in
            guard let self, self.token == current else { return }
            guard let image else {
                MidgarLog.debug("Recap art miss \(title) / \(artist), remote=\(remoteURL != nil), fallback=\(remoteFallback != nil)", category: .content)
                if let remoteURL {
                    self.setRemote(remoteURL, placeholder: placeholder, alsoCache: thumbKey)
                } else if let remoteFallback {
                    self.resolveRemote(remoteFallback, placeholder: placeholder, albumKey: thumbKey, token: current)
                } else {
                    Self.markMiss(thumbKey)
                    self.endShimmer()
                }
                return
            }
            Self.decodeQueue.async { [weak self] in
                guard let self, let thumb = Self.prepared(image) else { return }
                self.deliver(thumb, keys: [thumbKey], token: current)
            }
        }
    }

    func resolveRemote(_ query: RecapArtworkQuery, placeholder: UIImage?, albumKey: String, token current: UUID) {
        Task { [weak self] in
            let url = await RecapRemoteArtworkResolver.shared.resolvedURL(for: query)
            await MainActor.run {
                guard let self, self.token == current else { return }
                guard let url else { Self.markMiss(albumKey); self.endShimmer(); return }
                self.setRemote(url, placeholder: placeholder, alsoCache: albumKey)
            }
        }
    }

    func setPlaceholder(_ placeholder: UIImage?) {
        if image !== placeholder { image = placeholder }
    }

    func setImageIfChanged(_ newImage: UIImage) {
        if image !== newImage { image = newImage }
    }

    nonisolated func deliver(_ image: UIImage, keys: [String], token current: UUID) {
        for key in keys { Self.thumbnailCache.setObject(image, forKey: key as NSString) }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.token == current else { return }
                self.endShimmer()
                self.set(image, animated: true)
            }
        }
    }

    nonisolated func finishShimmer(token current: UUID) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.token == current else { return }
                self.endShimmer()
            }
        }
    }

    func configureShimmerLayer() {
        let base = UIColor.white.withAlphaComponent(0.06).cgColor
        let highlight = UIColor.white.withAlphaComponent(0.18).cgColor
        shimmerLayer.colors = [base, highlight, base]
        shimmerLayer.locations = [0, 0.5, 1]
        shimmerLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmerLayer.isHidden = true
    }

    func beginShimmer() {
        shimmerLayer.frame = bounds
        if shimmerLayer.superlayer == nil { layer.addSublayer(shimmerLayer) }
        shimmerLayer.isHidden = false
        guard !isShimmering else { return }
        isShimmering = true
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-1.0, -0.5, 0.0]
        sweep.toValue = [1.0, 1.5, 2.0]
        sweep.duration = 1.35
        sweep.repeatCount = .infinity
        shimmerLayer.add(sweep, forKey: "shimmer")
    }

    func endShimmer() {
        guard isShimmering || !shimmerLayer.isHidden else { return }
        isShimmering = false
        shimmerLayer.removeAnimation(forKey: "shimmer")
        shimmerLayer.isHidden = true
    }

    nonisolated static func downsampled(from data: Data) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return UIImage(data: data)?.preparingForDisplay() }
        return UIImage(cgImage: cgImage)
    }

    nonisolated static func prepared(_ image: UIImage) -> UIImage? {
        let longestPixels = max(image.size.width, image.size.height) * image.scale
        guard longestPixels > maxPixelSize else { return image.preparingForDisplay() ?? image }
        let ratio = maxPixelSize / longestPixels
        let targetPixels = CGSize(
            width: image.size.width * image.scale * ratio,
            height: image.size.height * image.scale * ratio
        )
        return image.preparingThumbnail(of: targetPixels) ?? image.preparingForDisplay() ?? image
    }

    func set(_ image: UIImage, animated: Bool) {
        guard animated, !UIAccessibility.isReduceMotionEnabled else { self.image = image; return }
        UIView.transition(with: self, duration: 0.2, options: .transitionCrossDissolve) { self.image = image }
    }

    /// Resolves and decodes one chart entry's artwork off the main thread into the
    /// same static thumbnail cache the cells read, so a later `setAlbum` becomes a
    /// synchronous cache hit. Returns `true` when an image was cached. A genuine
    /// absence (no local art, no resolvable URL, or a failed download) is recorded
    /// in the negative cache so the cell shows its placeholder without retrying; a
    /// cancellation (prewarm timed out) is left un-cached so the cell can retry.
    nonisolated static func prewarmAlbum(
        title: String,
        artist: String,
        remoteURL: String?,
        remoteFallback: RecapArtworkQuery?
    ) async -> Bool {
        let thumbKey = albumKey(title: title, artist: artist)
        if thumbnailCache.object(forKey: thumbKey as NSString) != nil { return true }
        if negativeCache.object(forKey: thumbKey as NSString) != nil { return false }
        if Task.isCancelled { return false }

        if let local = await loadLocalArtwork(title: title, artist: artist),
           let thumb = await decodeOffMain({ prepared(local) }) {
            thumbnailCache.setObject(thumb, forKey: thumbKey as NSString)
            return true
        }
        if Task.isCancelled { return false }

        var urlString = remoteURL
        if urlString == nil, let remoteFallback {
            urlString = await RecapRemoteArtworkResolver.shared.resolvedURL(for: remoteFallback)
        }
        guard let urlString, let url = URL(string: urlString) else {
            markMiss(thumbKey)
            return false
        }
        if Task.isCancelled { return false }

        if let cached = ImageCache.shared.image(forKey: urlString),
           let thumb = await decodeOffMain({ prepared(cached) }) {
            thumbnailCache.setObject(thumb, forKey: thumbKey as NSString)
            thumbnailCache.setObject(thumb, forKey: "remote:\(urlString)" as NSString)
            return true
        }
        guard let data = try? await RemoteImageClient().data(from: url).0 else {
            if !Task.isCancelled { markMiss(thumbKey) }
            return false
        }
        ImageCache.shared.store(data: data, forKey: urlString)
        guard let thumb = await decodeOffMain({ downsampled(from: data) }) else {
            markMiss(thumbKey)
            return false
        }
        thumbnailCache.setObject(thumb, forKey: thumbKey as NSString)
        thumbnailCache.setObject(thumb, forKey: "remote:\(urlString)" as NSString)
        return true
    }

    nonisolated static func loadLocalArtwork(title: String, artist: String) async -> UIImage? {
        if let cached = AlbumArtworkCache.shared.artwork(forAlbum: title, artist: artist) { return cached }
        return await withCheckedContinuation { continuation in
            AlbumArtworkCache.shared.loadArtwork(forAlbum: title, artist: artist) { image in
                continuation.resume(returning: image)
            }
        }
    }

    nonisolated static func decodeOffMain(_ work: @escaping @Sendable () -> UIImage?) async -> UIImage? {
        await withCheckedContinuation { continuation in
            decodeQueue.async { continuation.resume(returning: work()) }
        }
    }
}
