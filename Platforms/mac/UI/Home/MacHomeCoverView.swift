import AppKit
import CoreImage
import FlaccyCore

/// A Home cover: one album full bleed, or up to four composed as a mosaic, on
/// the family placeholder gradient until the pictures decode. A playlist the
/// person gave a picture shows it over the mosaic. It repaints itself when an
/// album's artwork is edited.
final class MacHomeCoverView: NSView {

    enum Tier {
        case thumbnail
        case large
    }

    struct Subject: Equatable {
        var albums: [Album]
        var seed: String
        var playlistID: Int64?
    }

    var cornerRadius: CGFloat {
        didSet { clip.cornerRadius = cornerRadius }
    }

    private let tier: Tier
    private let clip = CALayer()
    private let customLayer = CALayer()
    private var tiles: [CALayer] = []
    private var subject: Subject?
    private var generation = 0
    private var artworkObserver: ArtworkChangeObserver?

    init(cornerRadius: CGFloat, tier: Tier = .thumbnail, shadow: Bool = false) {
        self.cornerRadius = cornerRadius
        self.tier = tier
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        clip.cornerRadius = cornerRadius
        clip.cornerCurve = .continuous
        clip.masksToBounds = true
        layer?.addSublayer(clip)

        customLayer.contentsGravity = .resizeAspectFill
        customLayer.masksToBounds = true
        customLayer.opacity = 0

        if shadow {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.35
            layer?.shadowRadius = 18
            layer?.shadowOffset = CGSize(width: 0, height: -8)
        }
        artworkObserver = ArtworkChangeObserver { [weak self] in self?.reloadTiles() }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        customLayer.frame = bounds
        layoutTiles()
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
        )
        CATransaction.commit()
    }

    func show(_ subject: Subject) {
        guard subject != self.subject else { return }
        self.subject = subject
        rebuildTiles()
    }

    private func rebuildTiles() {
        generation += 1
        tiles.forEach { $0.removeFromSuperlayer() }
        tiles = []
        guard let subject else { return }
        let albums = Array(subject.albums.prefix(4))
        if albums.isEmpty {
            let placeholder = PlaceholderGradient.layer(seed: subject.seed)
            clip.addSublayer(placeholder)
            tiles = [placeholder]
        } else {
            for album in albums {
                let tile = CALayer()
                tile.contentsGravity = .resizeAspectFill
                tile.masksToBounds = true
                let placeholder = PlaceholderGradient.layer(seed: album.id)
                placeholder.name = "placeholder"
                tile.addSublayer(placeholder)
                clip.addSublayer(tile)
                tiles.append(tile)
            }
        }
        customLayer.removeFromSuperlayer()
        clip.addSublayer(customLayer)
        customLayer.opacity = 0
        customLayer.contents = nil
        needsLayout = true
        layoutSubtreeIfNeeded()
        reloadTiles()
    }

    /// Asks the cache for every tile again and puts each picture on its tile
    /// as it arrives, leaving the old one showing until then; an answer that
    /// belongs to an earlier subject is ignored.
    private func reloadTiles() {
        guard let subject else { return }
        let token = generation
        let albums = Array(subject.albums.prefix(4))
        for (index, album) in albums.enumerated() where tiles.indices.contains(index) {
            let tile = tiles[index]
            if let cached = cachedImage(for: album) {
                apply(cached, to: tile)
                continue
            }
            loadImage(for: album) { [weak self, weak tile] image in
                guard let self, let tile, self.generation == token else { return }
                if let image { self.apply(image, to: tile) }
            }
        }
        loadCustomCover(for: subject, token: token)
    }

    private func cachedImage(for album: Album) -> NSImage? {
        switch tier {
        case .thumbnail: AlbumArtworkCache.shared.thumbnail(forAlbum: album.title, artist: album.artist)
        case .large: AlbumArtworkCache.shared.nowPlayingArtwork(forAlbum: album.title, artist: album.artist)
        }
    }

    private func loadImage(for album: Album, completion: @escaping (NSImage?) -> Void) {
        switch tier {
        case .thumbnail:
            AlbumArtworkCache.shared.loadThumbnail(forAlbum: album.title, artist: album.artist, completion: completion)
        case .large:
            AlbumArtworkCache.shared.loadNowPlayingArtwork(forAlbum: album.title, artist: album.artist, completion: completion)
        }
    }

    private func apply(_ image: NSImage, to tile: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.contentsScale = window?.backingScaleFactor ?? 2
        tile.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        tile.sublayers?.first { $0.name == "placeholder" }?.removeFromSuperlayer()
        CATransaction.commit()
    }

    private func loadCustomCover(for subject: Subject, token: Int) {
        guard let playlistID = subject.playlistID else { return }
        let title = PlaylistCover.title(forPlaylist: playlistID)
        let artist = PlaylistCover.artist
        let show: (NSImage?) -> Void = { [weak self] image in
            guard let self, self.generation == token else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.customLayer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            self.customLayer.opacity = image == nil ? 0 : 1
            CATransaction.commit()
        }
        if let cached = AlbumArtworkCache.shared.thumbnail(forAlbum: title, artist: artist) {
            show(cached)
        } else {
            AlbumArtworkCache.shared.loadThumbnail(forAlbum: title, artist: artist, completion: show)
        }
    }

    private func layoutTiles() {
        let w = bounds.width
        let h = bounds.height
        switch tiles.count {
        case 1:
            tiles[0].frame = bounds
        case 2:
            tiles[0].frame = CGRect(x: 0, y: 0, width: w / 2, height: h)
            tiles[1].frame = CGRect(x: w / 2, y: 0, width: w / 2, height: h)
        case 3:
            tiles[0].frame = CGRect(x: 0, y: 0, width: w / 2, height: h)
            tiles[1].frame = CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2)
            tiles[2].frame = CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2)
        case 4:
            tiles[0].frame = CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2)
            tiles[1].frame = CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2)
            tiles[2].frame = CGRect(x: 0, y: 0, width: w / 2, height: h / 2)
            tiles[3].frame = CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2)
        default:
            break
        }
        for tile in tiles {
            tile.sublayers?.forEach { $0.frame = tile.bounds }
        }
    }
}

/// The soft colour wash behind the top of Home: the hero's cover, shrunk,
/// blurred once and stretched back up, fading into the window background.
final class MacHomeBackdropView: NSView {

    static let height: CGFloat = 640

    private let imageLayer = CALayer()
    private let fade = CAGradientLayer()
    private var generation = 0
    private var currentKey: String?
    private var artworkObserver: ArtworkChangeObserver?
    private var album: Album?

    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    private static var blurred: [String: CGImage] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        layer?.addSublayer(imageLayer)

        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.35, 1]
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.mask = fade
        artworkObserver = ArtworkChangeObserver { [weak self] in self?.reload() }
        restyle()
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        fade.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        imageLayer.opacity = effectiveAppearance.isDark ? 0.5 : 0.4
    }

    func show(_ album: Album?) {
        self.album = album
        currentKey = nil
        reload()
    }

    private func reload() {
        guard let album else {
            imageLayer.contents = nil
            return
        }
        let key = album.id
        generation += 1
        let token = generation
        if let cached = Self.blurred[key], currentKey == nil || currentKey == key {
            imageLayer.contents = cached
            currentKey = key
        }
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: album.title, artist: album.artist) { [weak self] image in
            guard let self, self.generation == token, let image else { return }
            guard let wash = Self.wash(of: image) else { return }
            Self.blurred[key] = wash
            self.currentKey = key
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.4)
            self.imageLayer.contents = wash
            CATransaction.commit()
        }
    }

    /// The cover at 96 px with a heavy Gaussian blur and a lift in colour.
    private static func wash(of image: NSImage) -> CGImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let source = CIImage(cgImage: cgImage)
        let scale = 96 / max(source.extent.width, source.extent.height)
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let clamped = small.clampedToExtent()
        guard let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: clamped, kCIInputRadiusKey: 9]),
              let blurred = blur.outputImage,
              let lift = CIFilter(name: "CIColorControls", parameters: [
                  kCIInputImageKey: blurred, kCIInputSaturationKey: 1.35, kCIInputBrightnessKey: 0.02,
              ]),
              let output = lift.outputImage?.cropped(to: small.extent)
        else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}
