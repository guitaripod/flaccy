import ImageIO
import UIKit

/// A remote-artwork lookup for a Recap chart entry that has no local match and no
/// artwork URL of its own. Resolved once against Last.fm, then cached.
nonisolated enum RecapArtworkQuery: Sendable, Hashable {
    case album(artist: String, album: String)
    case track(artist: String, track: String)

    fileprivate var cacheKey: String {
        switch self {
        case let .album(artist, album): "album\u{0}\(artist)\u{0}\(album)"
        case let .track(artist, track): "track\u{0}\(artist)\u{0}\(track)"
        }
    }
}

/// Resolves cover-art URLs for scrobble-derived chart entries that are absent from
/// the local library, via Last.fm's `album.getInfo` / `track.getInfo`. Results
/// (including misses) are memoised in-memory and keyed by album/track+artist so a
/// given entry hits the network at most once, and concurrent cells for the same
/// entry share a single in-flight request.
actor RecapRemoteArtworkResolver {
    static let shared = RecapRemoteArtworkResolver()

    private var cache: [String: String?] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]

    func resolvedURL(for query: RecapArtworkQuery) async -> String? {
        let key = query.cacheKey
        if let cached = cache[key] {
            AppLogger.debug("Recap remote art cache hit \(key) -> \(cached ?? "nil")", category: .content)
            return cached
        }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<String?, Never> { await Self.fetch(query) }
        inFlight[key] = task
        let url = await task.value
        inFlight[key] = nil
        cache[key] = url
        AppLogger.debug("Recap remote art resolved \(key) -> \(url ?? "miss")", category: .content)
        return url
    }

    private static func fetch(_ query: RecapArtworkQuery) async -> String? {
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

    private static let maxPixelSize: CGFloat = 600

    private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 256
        return cache
    }()

    /// Records entries that provably have no artwork (no local art, no remote URL,
    /// or a failed download) so a reconfigured cell shows its placeholder instantly
    /// instead of kicking off the same doomed lookup on every scroll pass.
    private static let negativeCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 512
        return cache
    }()

    private static func markMiss(_ key: NSString) {
        negativeCache.setObject(NSNumber(value: true), forKey: key)
    }

    private static func albumKey(title: String, artist: String) -> NSString {
        "album:\(title)\u{0}\(artist)" as NSString
    }

    private static let decodeQueue = DispatchQueue(
        label: "com.midgarcorp.flaccy.recap.decode",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private var token = UUID()
    private let shimmerLayer = CAGradientLayer()
    private var isShimmering = false

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
    func setRemote(_ urlString: String?, placeholder: UIImage?, alsoCache extraKey: NSString? = nil) {
        guard let urlString, let url = URL(string: urlString) else {
            token = UUID(); setPlaceholder(placeholder); endShimmer(); return
        }
        let thumbKey = "remote:\(urlString)" as NSString
        if let thumb = Self.thumbnailCache.object(forKey: thumbKey) {
            token = UUID()
            if let extraKey { Self.thumbnailCache.setObject(thumb, forKey: extraKey) }
            setImageIfChanged(thumb)
            endShimmer()
            return
        }
        if Self.negativeCache.object(forKey: thumbKey) != nil {
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
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let self else { return }
                guard let data, let thumb = Self.downsampled(from: data) else {
                    Self.markMiss(thumbKey)
                    self.finishShimmer(token: current)
                    return
                }
                ImageCache.shared.store(data: data, forKey: urlString)
                self.deliver(thumb, keys: keys, token: current)
            }.resume()
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
        if let thumb = Self.thumbnailCache.object(forKey: thumbKey) {
            token = UUID()
            setImageIfChanged(thumb)
            endShimmer()
            return
        }
        if Self.negativeCache.object(forKey: thumbKey) != nil {
            token = UUID(); setPlaceholder(placeholder); endShimmer(); return
        }

        let current = UUID()
        token = current
        setPlaceholder(placeholder)
        beginShimmer()
        if let cached = AlbumArtworkCache.shared.artwork(forAlbum: title, artist: artist) {
            Self.decodeQueue.async { [weak self] in
                guard let self, let thumb = Self.prepared(cached) else { return }
                self.deliver(thumb, keys: [thumbKey], token: current)
            }
            return
        }

        AlbumArtworkCache.shared.loadArtwork(forAlbum: title, artist: artist) { [weak self] image in
            guard let self, self.token == current else { return }
            guard let image else {
                AppLogger.debug("Recap art miss \(title) / \(artist), remote=\(remoteURL != nil), fallback=\(remoteFallback != nil)", category: .content)
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

    private func resolveRemote(_ query: RecapArtworkQuery, placeholder: UIImage?, albumKey: NSString, token current: UUID) {
        Task { [weak self] in
            let url = await RecapRemoteArtworkResolver.shared.resolvedURL(for: query)
            await MainActor.run {
                guard let self, self.token == current else { return }
                guard let url else { Self.markMiss(albumKey); self.endShimmer(); return }
                self.setRemote(url, placeholder: placeholder, alsoCache: albumKey)
            }
        }
    }

    private func setPlaceholder(_ placeholder: UIImage?) {
        if image !== placeholder { image = placeholder }
    }

    private func setImageIfChanged(_ newImage: UIImage) {
        if image !== newImage { image = newImage }
    }

    private func deliver(_ image: UIImage, keys: [NSString], token current: UUID) {
        for key in keys { Self.thumbnailCache.setObject(image, forKey: key) }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.token == current else { return }
            self.endShimmer()
            self.set(image, animated: true)
        }
    }

    private func finishShimmer(token current: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.token == current else { return }
            self.endShimmer()
        }
    }

    private func configureShimmerLayer() {
        let base = UIColor.white.withAlphaComponent(0.06).cgColor
        let highlight = UIColor.white.withAlphaComponent(0.18).cgColor
        shimmerLayer.colors = [base, highlight, base]
        shimmerLayer.locations = [0, 0.5, 1]
        shimmerLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmerLayer.isHidden = true
    }

    private func beginShimmer() {
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

    private func endShimmer() {
        guard isShimmering || !shimmerLayer.isHidden else { return }
        isShimmering = false
        shimmerLayer.removeAnimation(forKey: "shimmer")
        shimmerLayer.isHidden = true
    }

    private static func downsampled(from data: Data) -> UIImage? {
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

    private static func prepared(_ image: UIImage) -> UIImage? {
        let longestPixels = max(image.size.width, image.size.height) * image.scale
        guard longestPixels > maxPixelSize else { return image.preparingForDisplay() ?? image }
        let ratio = maxPixelSize / longestPixels
        let targetPixels = CGSize(
            width: image.size.width * image.scale * ratio,
            height: image.size.height * image.scale * ratio
        )
        return image.preparingThumbnail(of: targetPixels) ?? image.preparingForDisplay() ?? image
    }

    private func set(_ image: UIImage, animated: Bool) {
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
        if thumbnailCache.object(forKey: thumbKey) != nil { return true }
        if negativeCache.object(forKey: thumbKey) != nil { return false }
        if Task.isCancelled { return false }

        if let local = await loadLocalArtwork(title: title, artist: artist),
           let thumb = await decodeOffMain({ prepared(local) }) {
            thumbnailCache.setObject(thumb, forKey: thumbKey)
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
            thumbnailCache.setObject(thumb, forKey: thumbKey)
            thumbnailCache.setObject(thumb, forKey: "remote:\(urlString)" as NSString)
            return true
        }
        guard let data = try? await URLSession.shared.data(from: url).0 else {
            if !Task.isCancelled { markMiss(thumbKey) }
            return false
        }
        ImageCache.shared.store(data: data, forKey: urlString)
        guard let thumb = await decodeOffMain({ downsampled(from: data) }) else {
            markMiss(thumbKey)
            return false
        }
        thumbnailCache.setObject(thumb, forKey: thumbKey)
        thumbnailCache.setObject(thumb, forKey: "remote:\(urlString)" as NSString)
        return true
    }

    nonisolated private static func loadLocalArtwork(title: String, artist: String) async -> UIImage? {
        if let cached = AlbumArtworkCache.shared.artwork(forAlbum: title, artist: artist) { return cached }
        return await withCheckedContinuation { continuation in
            AlbumArtworkCache.shared.loadArtwork(forAlbum: title, artist: artist) { image in
                continuation.resume(returning: image)
            }
        }
    }

    nonisolated private static func decodeOffMain(_ work: @escaping @Sendable () -> UIImage?) async -> UIImage? {
        await withCheckedContinuation { continuation in
            decodeQueue.async { continuation.resume(returning: work()) }
        }
    }
}

/// Shared number formatting: grouped counts and a compact minutes-to-hours label.
enum RecapFormat {
    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func count(_ value: Int) -> String {
        decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 10_000 { return String(format: "%.0fK", Double(value) / 1_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}

private func recapCard(cornerRadius: CGFloat = 22) -> UIView {
    let card = UIView()
    if UIAccessibility.isReduceTransparencyEnabled {
        card.backgroundColor = UIColor.white.withAlphaComponent(0.1)
    } else {
        card.backgroundColor = UIColor.white.withAlphaComponent(0.06)
    }
    card.layer.cornerRadius = cornerRadius
    card.layer.cornerCurve = .continuous
    card.layer.borderWidth = 0.5
    card.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
    return card
}

/// Section header shown above the top-lists and visualizations.
final class RecapHeaderView: UICollectionReusableView {
    static let reuseID = "RecapHeaderView"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .scaled(.title3, size: 20, weight: .bold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String) {
        label.text = title
        accessibilityTraits = .header
    }
}

final class ProfileCell: UICollectionViewCell {
    static let reuseID = "ProfileCell"

    private let avatar = AsyncImageView()
    private let nameLabel = UILabel()
    private let sinceLabel = UILabel()
    private let playsValue = UILabel()
    private let minutesValue = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        avatar.layer.cornerRadius = 34
        avatar.layer.borderWidth = 1
        avatar.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        avatar.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .scaled(.largeTitle, size: 28, weight: .heavy)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 1

        sinceLabel.font = .scaled(.subheadline, size: 14, weight: .medium)
        sinceLabel.adjustsFontForContentSizeCategory = true
        sinceLabel.textColor = UIColor.white.withAlphaComponent(0.6)

        let identity = UIStackView(arrangedSubviews: [nameLabel, sinceLabel])
        identity.axis = .vertical
        identity.spacing = 2

        let topRow = UIStackView(arrangedSubviews: [avatar, identity])
        topRow.axis = .horizontal
        topRow.spacing = 14
        topRow.alignment = .center

        let playsStat = Self.statColumn(value: playsValue, caption: "plays")
        let minutesStat = Self.statColumn(value: minutesValue, caption: "minutes")
        let statsRow = UIStackView(arrangedSubviews: [playsStat, minutesStat])
        statsRow.axis = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.spacing = 12

        let statsCard = recapCard()
        statsCard.translatesAutoresizingMaskIntoConstraints = false
        statsRow.translatesAutoresizingMaskIntoConstraints = false
        statsCard.addSubview(statsRow)
        NSLayoutConstraint.activate([
            statsRow.topAnchor.constraint(equalTo: statsCard.topAnchor, constant: 18),
            statsRow.bottomAnchor.constraint(equalTo: statsCard.bottomAnchor, constant: -18),
            statsRow.leadingAnchor.constraint(equalTo: statsCard.leadingAnchor, constant: 8),
            statsRow.trailingAnchor.constraint(equalTo: statsCard.trailingAnchor, constant: -8),
        ])

        let main = UIStackView(arrangedSubviews: [topRow, statsCard])
        main.axis = .vertical
        main.spacing = 16
        main.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(main)

        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 68),
            avatar.heightAnchor.constraint(equalToConstant: 68),
            main.topAnchor.constraint(equalTo: contentView.topAnchor),
            main.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            main.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            main.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func statColumn(value: UILabel, caption: String) -> UIStackView {
        value.font = .scaled(.largeTitle, size: 34, weight: .heavy, maxSize: 44)
        value.adjustsFontForContentSizeCategory = true
        value.textColor = .white
        value.textAlignment = .center
        value.adjustsFontSizeToFitWidth = true
        value.minimumScaleFactor = 0.5

        let captionLabel = UILabel()
        captionLabel.font = .scaled(.caption1, size: 12, weight: .semibold)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        captionLabel.textAlignment = .center
        captionLabel.text = caption.uppercased()

        let stack = UIStackView(arrangedSubviews: [value, captionLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .center
        return stack
    }

    func configure(_ item: ProfileItem) {
        nameLabel.text = item.username
        sinceLabel.text = item.sinceText
        sinceLabel.isHidden = item.sinceText == nil
        playsValue.text = RecapFormat.count(item.totalPlays)
        minutesValue.text = RecapFormat.count(item.totalMinutes)
        avatar.setRemote(item.avatarURL, placeholder: UIImage(systemName: "person.crop.circle.fill"))

        isAccessibilityElement = true
        accessibilityLabel = "\(item.username). \(item.sinceText ?? ""). \(RecapFormat.count(item.totalPlays)) plays, \(RecapFormat.count(item.totalMinutes)) minutes listened."
    }
}

final class ImportBannerCell: UICollectionViewCell {
    static let reuseID = "ImportBannerCell"

    private let card = recapCard(cornerRadius: 18)
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let chevron = UIImageView(image: UIImage(systemName: "arrow.down.circle.fill"))
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        iconView.image = UIImage(systemName: "clock.arrow.circlepath")
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)

        titleLabel.font = .scaled(.subheadline, size: 15, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white

        subtitleLabel.font = .scaled(.caption1, size: 12, weight: .regular)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        subtitleLabel.numberOfLines = 2

        chevron.tintColor = UIColor.white.withAlphaComponent(0.8)
        chevron.contentMode = .scaleAspectFit
        spinner.color = .white
        spinner.hidesWhenStopped = true

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 1

        let trailing = UIStackView(arrangedSubviews: [spinner, chevron])
        trailing.axis = .horizontal

        let row = UIStackView(arrangedSubviews: [iconView, textStack, trailing])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        contentView.addSubview(card)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 28),
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        card.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handleTap() { onTap?() }

    func configure(state: RecapImportState) {
        switch state {
        case .available:
            titleLabel.text = "Import Last.fm history"
            subtitleLabel.text = "Backfill your stats with everything you scrobbled before installing."
            spinner.stopAnimating()
            chevron.isHidden = false
            card.isUserInteractionEnabled = true
            accessibilityHint = "Double tap to import"
        case .importing(let imported):
            titleLabel.text = "Importing history\u{2026}"
            subtitleLabel.text = imported > 0
                ? "\(RecapFormat.count(imported)) scrobbles imported so far\u{2026}"
                : "This can take a moment. You can keep browsing."
            spinner.startAnimating()
            chevron.isHidden = true
            card.isUserInteractionEnabled = false
            accessibilityHint = nil
        case .done(let imported):
            titleLabel.text = "History imported"
            subtitleLabel.text = imported > 0
                ? "Imported \(RecapFormat.count(imported)) scrobbles."
                : "Your stats now include your full listening history."
            spinner.stopAnimating()
            chevron.isHidden = true
            card.isUserInteractionEnabled = false
            accessibilityHint = nil
        case .unavailable:
            titleLabel.text = "Connect Last.fm to import"
            subtitleLabel.text = "Sign in from Settings to backfill your history."
            spinner.stopAnimating()
            chevron.isHidden = true
            card.isUserInteractionEnabled = false
            accessibilityHint = nil
        }
        isAccessibilityElement = true
        accessibilityLabel = [titleLabel.text, subtitleLabel.text].compactMap { $0 }.joined(separator: ". ")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTap = nil
    }
}

final class ArtistCardCell: UICollectionViewCell {
    static let reuseID = "ArtistCardCell"

    private let rankLabel = UILabel()
    private let initialLabel = UILabel()
    private let nameLabel = UILabel()
    private let playsLabel = UILabel()
    private let disc = UIView()
    private let cover = AsyncImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        disc.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        disc.layer.cornerRadius = 40
        disc.layer.masksToBounds = true
        disc.translatesAutoresizingMaskIntoConstraints = false

        cover.layer.cornerRadius = 40
        cover.layer.masksToBounds = true
        cover.isHidden = true
        cover.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(cover)

        initialLabel.font = .scaled(.largeTitle, size: 30, weight: .bold)
        initialLabel.textColor = .white
        initialLabel.textAlignment = .center
        initialLabel.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(initialLabel)

        rankLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        rankLabel.textColor = .black
        rankLabel.textAlignment = .center
        rankLabel.backgroundColor = .white
        rankLabel.layer.cornerRadius = 11
        rankLabel.layer.masksToBounds = true
        rankLabel.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .scaled(.footnote, size: 13, weight: .semibold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .white
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2

        playsLabel.font = .scaled(.caption2, size: 11, weight: .regular)
        playsLabel.adjustsFontForContentSizeCategory = true
        playsLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        playsLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [disc, nameLabel, playsLabel])
        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.addSubview(rankLabel)

        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: 80),
            disc.heightAnchor.constraint(equalToConstant: 80),
            cover.topAnchor.constraint(equalTo: disc.topAnchor),
            cover.bottomAnchor.constraint(equalTo: disc.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: disc.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: disc.trailingAnchor),
            initialLabel.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            initialLabel.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            rankLabel.widthAnchor.constraint(equalToConstant: 22),
            rankLabel.heightAnchor.constraint(equalToConstant: 22),
            rankLabel.centerXAnchor.constraint(equalTo: disc.trailingAnchor, constant: -8),
            rankLabel.centerYAnchor.constraint(equalTo: disc.topAnchor, constant: 8),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: RecapArtistItem, tint: UIColor) {
        initialLabel.text = String(item.name.prefix(1)).uppercased()
        nameLabel.text = item.name
        playsLabel.text = item.playCount > 0 ? "\(RecapFormat.compact(item.playCount)) plays" : "New to you"
        rankLabel.text = "\(item.rank)"
        disc.backgroundColor = tint.withAlphaComponent(0.28)

        if let title = item.artworkTitle, let artist = item.artworkArtist {
            cover.isHidden = false
            initialLabel.isHidden = true
            cover.setAlbum(title: title, artist: artist, remoteURL: nil, placeholder: nil)
        } else {
            cover.isHidden = true
            initialLabel.isHidden = false
        }

        isAccessibilityElement = true
        let ownership = item.isLocal ? ", in your library, double tap to start a station" : ""
        accessibilityLabel = "Number \(item.rank), \(item.name), \(item.playCount) plays\(ownership)"
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cover.isHidden = true
        initialLabel.isHidden = false
    }
}

final class AlbumCoverCell: UICollectionViewCell {
    static let reuseID = "AlbumCoverCell"

    private let cover = AsyncImageView()
    private let nameLabel = UILabel()
    private let rankLabel = UILabel()
    private let playBadge = UIImageView(image: UIImage(systemName: "play.circle.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)

        cover.layer.cornerRadius = 10
        cover.layer.cornerCurve = .continuous
        cover.translatesAutoresizingMaskIntoConstraints = false

        playBadge.tintColor = .white
        playBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        playBadge.contentMode = .scaleAspectFit
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.45
        playBadge.layer.shadowRadius = 3
        playBadge.layer.shadowOffset = .zero
        playBadge.isHidden = true
        playBadge.translatesAutoresizingMaskIntoConstraints = false

        rankLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        rankLabel.textColor = .white
        rankLabel.textAlignment = .center
        rankLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        rankLabel.layer.cornerRadius = 9
        rankLabel.layer.masksToBounds = true
        rankLabel.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .scaled(.caption2, size: 11, weight: .medium)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        nameLabel.numberOfLines = 1

        let stack = UIStackView(arrangedSubviews: [cover, nameLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.addSubview(rankLabel)
        contentView.addSubview(playBadge)

        NSLayoutConstraint.activate([
            cover.widthAnchor.constraint(equalTo: cover.heightAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rankLabel.widthAnchor.constraint(equalToConstant: 18),
            rankLabel.heightAnchor.constraint(equalToConstant: 18),
            rankLabel.leadingAnchor.constraint(equalTo: cover.leadingAnchor, constant: 5),
            rankLabel.topAnchor.constraint(equalTo: cover.topAnchor, constant: 5),
            playBadge.trailingAnchor.constraint(equalTo: cover.trailingAnchor, constant: -6),
            playBadge.bottomAnchor.constraint(equalTo: cover.bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: AlbumItem) {
        nameLabel.text = item.name
        rankLabel.text = "\(item.rank)"
        playBadge.isHidden = !item.isLocal
        let artTitle = item.artworkTitle ?? item.name
        let artArtist = item.artworkArtist ?? item.artist
        let fallback: RecapArtworkQuery? = item.isLocal ? nil : .album(artist: item.artist, album: item.name)
        cover.setAlbum(title: artTitle, artist: artArtist, remoteURL: item.imageURL, placeholder: UIImage(systemName: "square.stack"), remoteFallback: fallback)
        isAccessibilityElement = true
        let ownership = item.isLocal ? ", in your library, double tap to play" : ""
        accessibilityLabel = "Number \(item.rank), \(item.name) by \(item.artist), \(item.playCount) plays\(ownership)"
    }
}

final class TrackRowCell: UICollectionViewCell {
    static let reuseID = "TrackRowCell"

    private let rankLabel = UILabel()
    private let artwork = AsyncImageView()
    private let playBadge = UIImageView(image: UIImage(systemName: "play.circle.fill"))
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let playsLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        rankLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .bold)
        rankLabel.textAlignment = .center
        rankLabel.setContentHuggingPriority(.required, for: .horizontal)

        artwork.layer.cornerRadius = 6
        artwork.layer.cornerCurve = .continuous
        artwork.translatesAutoresizingMaskIntoConstraints = false

        playBadge.tintColor = .white
        playBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        playBadge.contentMode = .scaleAspectFit
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.45
        playBadge.layer.shadowRadius = 2
        playBadge.layer.shadowOffset = .zero
        playBadge.isHidden = true
        playBadge.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .scaled(.body, size: 16, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        artistLabel.font = .scaled(.caption1, size: 12, weight: .regular)
        artistLabel.adjustsFontForContentSizeCategory = true
        artistLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        artistLabel.numberOfLines = 1

        playsLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        playsLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        playsLabel.textAlignment = .right
        playsLabel.setContentHuggingPriority(.required, for: .horizontal)

        let info = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        info.axis = .vertical
        info.spacing = 1

        let row = UIStackView(arrangedSubviews: [rankLabel, artwork, info, playsLabel])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        contentView.addSubview(playBadge)

        NSLayoutConstraint.activate([
            rankLabel.widthAnchor.constraint(equalToConstant: 22),
            artwork.widthAnchor.constraint(equalToConstant: 40),
            artwork.heightAnchor.constraint(equalToConstant: 40),
            playBadge.centerXAnchor.constraint(equalTo: artwork.centerXAnchor),
            playBadge.centerYAnchor.constraint(equalTo: artwork.centerYAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func medalColor(for rank: Int) -> UIColor? {
        switch rank {
        case 1: .systemYellow
        case 2: .systemGray2
        case 3: .systemBrown
        default: nil
        }
    }

    func configure(_ item: TrackItem) {
        rankLabel.text = "\(item.rank)"
        rankLabel.textColor = Self.medalColor(for: item.rank) ?? UIColor.white.withAlphaComponent(0.5)
        titleLabel.text = item.name
        artistLabel.text = item.artist
        playsLabel.text = RecapFormat.compact(item.playCount)

        playBadge.isHidden = !item.isLocal
        contentView.alpha = item.isLocal ? 1.0 : 0.55
        let artTitle = item.artworkTitle ?? item.name
        let artArtist = item.artworkArtist ?? item.artist
        let fallback: RecapArtworkQuery? = item.isLocal ? nil : .track(artist: item.artist, track: item.name)
        artwork.setAlbum(title: artTitle, artist: artArtist, remoteURL: nil, placeholder: UIImage(systemName: "music.note"), remoteFallback: fallback)

        isAccessibilityElement = true
        let ownership = item.isLocal ? ", in your library, double tap to play" : ", not in your library"
        accessibilityLabel = "Number \(item.rank), \(item.name) by \(item.artist), \(item.playCount) plays\(ownership)"
    }
}

final class ClockCell: UICollectionViewCell {
    static let reuseID = "ClockCell"
    private let card = recapCard()
    private let clock = ListeningClockView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.translatesAutoresizingMaskIntoConstraints = false
        clock.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)
        card.addSubview(clock)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            clock.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            clock.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            clock.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            clock.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: ClockItem, tint: UIColor) {
        clock.configure(buckets: item.buckets, tint: tint)
    }
}

final class StreakCell: UICollectionViewCell {
    static let reuseID = "StreakCell"
    private let card = recapCard()
    private let flameLabel = UILabel()
    private let streakValue = UILabel()
    private let streakCaption = UILabel()
    private let heatmap = HeatmapView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        flameLabel.text = "\u{1F525}"
        flameLabel.font = .systemFont(ofSize: 30)

        streakValue.font = .scaled(.largeTitle, size: 34, weight: .heavy)
        streakValue.adjustsFontForContentSizeCategory = true
        streakValue.textColor = .white

        streakCaption.font = .scaled(.caption1, size: 12, weight: .semibold)
        streakCaption.adjustsFontForContentSizeCategory = true
        streakCaption.textColor = UIColor.white.withAlphaComponent(0.55)

        let valueRow = UIStackView(arrangedSubviews: [streakValue, streakCaption])
        valueRow.axis = .vertical
        valueRow.spacing = 0

        let topRow = UIStackView(arrangedSubviews: [flameLabel, valueRow])
        topRow.axis = .horizontal
        topRow.spacing = 10
        topRow.alignment = .center

        heatmap.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [topRow, heatmap])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: StreakItem, tint: UIColor) {
        let days = item.streakDays
        streakValue.text = "\(days)"
        streakCaption.text = days == 1 ? "DAY STREAK" : "DAY STREAK"
        heatmap.configure(counts: item.heatmap, tint: tint)
        isAccessibilityElement = false
    }
}

final class PersonaCell: UICollectionViewCell {
    static let reuseID = "PersonaCell"

    private let gradient = CAGradientLayer()
    private let card = UIView()
    private let iconView = UIImageView()
    private let personaLabel = UILabel()
    private let blurbLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.addSublayer(gradient)

        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .bold)

        personaLabel.font = .scaled(.title1, size: 28, weight: .heavy)
        personaLabel.adjustsFontForContentSizeCategory = true
        personaLabel.textColor = .white

        blurbLabel.font = .scaled(.subheadline, size: 15, weight: .medium)
        blurbLabel.adjustsFontForContentSizeCategory = true
        blurbLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        blurbLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [iconView, personaLabel, blurbLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        contentView.addSubview(card)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = card.bounds
    }

    func configure(_ item: PersonaItem, palette: ArtworkPalette) {
        personaLabel.text = item.persona
        blurbLabel.text = RecapPersona.blurb(for: item.persona)
        iconView.image = UIImage(systemName: RecapPersona.symbol(for: item.persona))
        let colors = palette.colors
        let first = (colors.first ?? .systemIndigo).cgColor
        let second = (colors.count > 2 ? colors[2] : colors.last ?? .systemPurple).cgColor
        gradient.colors = [first, second]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        isAccessibilityElement = true
        accessibilityLabel = "Your persona: \(item.persona). \(RecapPersona.blurb(for: item.persona))"
    }
}

final class PeriodSelectorCell: UICollectionViewCell {
    static let reuseID = "PeriodSelectorCell"

    private var capsules: [ChartPeriod: GlassCapsule] = [:]
    private let stack = UIStackView()
    private var selectedPeriod: ChartPeriod = .allTime
    var onSelect: ((ChartPeriod) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.spacing = 8
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        for period in RecapPeriods.all {
            let button = UIButton(type: .system)
            button.setTitle(period.shortName, for: .normal)
            button.titleLabel?.font = .scaled(.footnote, size: 13, weight: .semibold)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.setTitleColor(.white, for: .normal)
            button.accessibilityLabel = period.displayName
            button.addAction(UIAction { [weak self] _ in
                UISelectionFeedbackGenerator().selectionChanged()
                self?.onSelect?(period)
            }, for: .touchUpInside)
            let capsule = GlassCapsule(hosting: button, height: 38)
            capsule.isAccessibilityElement = false
            capsules[period] = capsule
            stack.addArrangedSubview(capsule)
        }
    }

    func configure(selected: ChartPeriod) {
        self.selectedPeriod = selected
        for (period, capsule) in capsules {
            let active = period == selected
            capsule.setActive(active, animated: !UIAccessibility.isReduceMotionEnabled)
            if let button = capsule.subviews.compactMap({ $0 as? UIButton }).first {
                button.accessibilityTraits = active ? [.button, .selected] : .button
            }
        }
    }
}

/// The 7D / 1M / 3M / 1Y / All subset of ChartPeriod the Recap surfaces.
enum RecapPeriods {
    static let all: [ChartPeriod] = [.week, .month, .threeMonths, .year, .allTime]
}

/// A single muted, rounded placeholder block with an animated diagonal sheen. On
/// Reduce Motion the sheen holds still, reading as a soft static card.
final class ShimmerBlock: UIView {
    private let sheen = CAGradientLayer()

    init(cornerRadius: CGFloat = 12) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.06)
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        sheen.colors = [
            UIColor.white.withAlphaComponent(0).cgColor,
            UIColor.white.withAlphaComponent(0.12).cgColor,
            UIColor.white.withAlphaComponent(0).cgColor,
        ]
        sheen.locations = [0, 0.5, 1]
        sheen.startPoint = CGPoint(x: 0, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(sheen)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        sheen.frame = bounds
    }

    func startAnimating() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-1.0, -0.5, 0.0]
        sweep.toValue = [1.0, 1.5, 2.0]
        sweep.duration = 1.35
        sweep.repeatCount = .infinity
        sheen.add(sweep, forKey: "shimmer")
    }

    func stopAnimating() { sheen.removeAnimation(forKey: "shimmer") }
}

/// A full-screen skeleton mirroring the Recap layout — profile, top-artist row,
/// album grid, track rows, clock, and heatmap — shown while a period's data is
/// still loading so the screen is never bare or a lone spinner. All blocks share
/// one shimmer that starts/stops with `startAnimating()`/`stopAnimating()`.
final class RecapSkeletonView: UIView {
    private var blocks: [ShimmerBlock] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func startAnimating() { blocks.forEach { $0.startAnimating() } }
    func stopAnimating() { blocks.forEach { $0.stopAnimating() } }

    private func block(_ cornerRadius: CGFloat = 12) -> ShimmerBlock {
        let block = ShimmerBlock(cornerRadius: cornerRadius)
        block.translatesAutoresizingMaskIntoConstraints = false
        blocks.append(block)
        return block
    }

    private func buildLayout() {
        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 22
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])

        content.addArrangedSubview(profileSkeleton())
        content.addArrangedSubview(pill(width: 220, height: 20))
        content.addArrangedSubview(artistRowSkeleton())
        content.addArrangedSubview(header())
        content.addArrangedSubview(albumGridSkeleton())
        content.addArrangedSubview(header())
        content.addArrangedSubview(trackListSkeleton())
        content.addArrangedSubview(fixedBlock(height: 200, cornerRadius: 22))
    }

    private func header() -> UIView {
        pill(width: 150, height: 22)
    }

    private func pill(width: CGFloat, height: CGFloat) -> UIView {
        let container = UIView()
        let bar = block(height / 2)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: width),
            bar.heightAnchor.constraint(equalToConstant: height),
        ])
        return container
    }

    private func fixedBlock(height: CGFloat, cornerRadius: CGFloat) -> ShimmerBlock {
        let block = block(cornerRadius)
        block.heightAnchor.constraint(equalToConstant: height).isActive = true
        return block
    }

    private func profileSkeleton() -> UIView {
        let avatar = block(34)
        NSLayoutConstraint.activate([
            avatar.widthAnchor.constraint(equalToConstant: 68),
            avatar.heightAnchor.constraint(equalToConstant: 68),
        ])
        let lines = UIStackView(arrangedSubviews: [pill(width: 160, height: 26), pill(width: 110, height: 14)])
        lines.axis = .vertical
        lines.spacing = 8
        lines.alignment = .leading

        let topRow = UIStackView(arrangedSubviews: [avatar, lines])
        topRow.axis = .horizontal
        topRow.spacing = 14
        topRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [topRow, fixedBlock(height: 84, cornerRadius: 22)])
        stack.axis = .vertical
        stack.spacing = 16
        return stack
    }

    private func artistRowSkeleton() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .top
        for _ in 0..<5 {
            let disc = block(40)
            NSLayoutConstraint.activate([
                disc.widthAnchor.constraint(equalToConstant: 80),
                disc.heightAnchor.constraint(equalToConstant: 80),
            ])
            row.addArrangedSubview(disc)
        }
        return row
    }

    private func albumGridSkeleton() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        for _ in 0..<3 {
            let cover = block(10)
            cover.heightAnchor.constraint(equalTo: cover.widthAnchor).isActive = true
            row.addArrangedSubview(cover)
        }
        return row
    }

    private func trackListSkeleton() -> UIView {
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 14
        for _ in 0..<4 {
            let art = block(6)
            NSLayoutConstraint.activate([
                art.widthAnchor.constraint(equalToConstant: 40),
                art.heightAnchor.constraint(equalToConstant: 40),
            ])
            let lines = UIStackView(arrangedSubviews: [pill(width: 180, height: 15), pill(width: 120, height: 11)])
            lines.axis = .vertical
            lines.spacing = 6
            lines.alignment = .leading
            let rowStack = UIStackView(arrangedSubviews: [art, lines])
            rowStack.axis = .horizontal
            rowStack.spacing = 12
            rowStack.alignment = .center
            column.addArrangedSubview(rowStack)
        }
        return column
    }
}
