import AppKit
import FlaccyCore

/// Playlist cover art: up to four distinct album covers composed as a 2x2
/// mosaic (three → large-plus-column, two → halves, one → full bleed), with
/// the placeholder gradient standing in for missing covers. A playlist the
/// person chose a picture for shows that picture full bleed over the mosaic
/// instead, and falls back to the mosaic the moment it is cleared.
final class MosaicArtworkView: NSView {

    private var tileLayers: [CALayer] = []
    private var currentKey: String?
    private var lastTracks: [Track] = []
    private var lastSeed = ""
    private var artworkObserver: ArtworkChangeObserver?
    private let customLayer = CALayer()
    private var playlistId: Int64?
    private var customRequest = 0

    private(set) var showsCustomCover = false

    /// Set by a surface that takes a picture dropped on the thumbnail. Music
    /// and folders dragged over it are handed on to the window's import.
    var onPictureDrop: ((ArtworkInput) -> Void)? {
        didSet { updateDropRegistration() }
    }

    private let dropRing = CALayer()
    private lazy var dropRelay = ArtworkDropRelay(view: self)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        artworkObserver = ArtworkChangeObserver { [weak self] in self?.artworkDidChange() }
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        customLayer.contentsGravity = .resizeAspectFill
        customLayer.masksToBounds = true
        customLayer.opacity = 0
        layer?.addSublayer(customLayer)
        dropRing.borderColor = NSColor.controlAccentColor.cgColor
        dropRing.borderWidth = 3
        dropRing.cornerRadius = 8
        dropRing.cornerCurve = .continuous
        dropRing.isHidden = true
        layer?.addSublayer(dropRing)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with tracks: [Track], fallbackSeed: String) {
        playlistId = nil
        customRequest += 1
        setCustomCover(nil, animated: false)
        renderMosaic(with: tracks, fallbackSeed: fallbackSeed)
    }

    /// Shows the playlist's own picture when it has one and the album mosaic
    /// otherwise. `hasCustomCover` is passed by a caller that already knows,
    /// which spares a plain playlist a lookup and a flash; nil asks the cache.
    func configure(playlistId: Int64, tracks: [Track], fallbackSeed: String, hasCustomCover: Bool? = nil) {
        let changed = self.playlistId != playlistId
        self.playlistId = playlistId
        renderMosaic(with: tracks, fallbackSeed: fallbackSeed)
        if changed { setCustomCover(nil, animated: false) }
        resolveCustomCover(known: hasCustomCover, animated: !changed)
    }

    private func artworkDidChange() {
        if playlistId != nil { resolveCustomCover(known: nil, animated: true) }
        guard !lastTracks.isEmpty else { return }
        currentKey = nil
        renderMosaic(with: lastTracks, fallbackSeed: lastSeed)
    }

    /// Asks the artwork cache for the playlist's chosen picture through its
    /// reserved key and shows or removes it; a stale answer, from before the
    /// view was reused or the picture changed again, is dropped.
    private func resolveCustomCover(known: Bool?, animated: Bool) {
        guard let playlistId else { return }
        customRequest += 1
        let request = customRequest
        guard known != false else {
            setCustomCover(nil, animated: animated)
            return
        }
        let title = PlaylistCover.title(forPlaylist: playlistId)
        let artist = PlaylistCover.artist
        if let cached = AlbumArtworkCache.shared.thumbnail(forAlbum: title, artist: artist) {
            setCustomCover(cached, animated: false)
            return
        }
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: title, artist: artist) { [weak self] image in
            guard let self, self.customRequest == request else { return }
            self.setCustomCover(image, animated: animated)
        }
    }

    private func setCustomCover(_ image: NSImage?, animated: Bool) {
        showsCustomCover = image != nil
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.showsCustomCover else { return }
            self.customLayer.contents = nil
        }
        if let image { customLayer.contents = image }
        customLayer.opacity = image == nil ? 0 : 1
        CATransaction.commit()
    }

    private func renderMosaic(with tracks: [Track], fallbackSeed: String) {
        lastTracks = tracks
        lastSeed = fallbackSeed
        var seenAlbums = [String]()
        var albumPairs = [(title: String, artist: String)]()
        for track in tracks {
            let key = "\(track.albumTitle)|\(track.artist)"
            guard !seenAlbums.contains(key) else { continue }
            seenAlbums.append(key)
            albumPairs.append((track.albumTitle, track.artist))
            if albumPairs.count == 4 { break }
        }

        let key = seenAlbums.joined(separator: "\u{0}")
        guard key != currentKey else { return }
        currentKey = key

        tileLayers.forEach { $0.removeFromSuperlayer() }
        tileLayers = []

        guard !albumPairs.isEmpty else {
            let gradient = PlaceholderGradient.layer(seed: fallbackSeed)
            layer?.addSublayer(gradient)
            tileLayers = [gradient]
            raiseCustomLayer()
            needsLayout = true
            return
        }

        for pair in albumPairs {
            let tile = CALayer()
            tile.contentsGravity = .resizeAspectFill
            tile.masksToBounds = true
            let placeholder = PlaceholderGradient.layer(seed: "\(pair.title)|\(pair.artist)")
            tile.addSublayer(placeholder)
            layer?.addSublayer(tile)
            tileLayers.append(tile)

            let expectedKey = key
            if let cached = AlbumArtworkCache.shared.thumbnail(forAlbum: pair.title, artist: pair.artist) {
                tile.contents = cached
                placeholder.removeFromSuperlayer()
            } else {
                AlbumArtworkCache.shared.loadThumbnail(forAlbum: pair.title, artist: pair.artist) { [weak self, weak tile] image in
                    guard let self, self.currentKey == expectedKey, let tile, let image else { return }
                    tile.contents = image
                    placeholder.removeFromSuperlayer()
                }
            }
        }
        raiseCustomLayer()
        needsLayout = true
    }

    private func raiseCustomLayer() {
        customLayer.removeFromSuperlayer()
        layer?.addSublayer(customLayer)
        dropRing.removeFromSuperlayer()
        layer?.addSublayer(dropRing)
    }

    private func updateDropRegistration() {
        if onPictureDrop == nil {
            unregisterDraggedTypes()
        } else {
            registerForDraggedTypes(ArtworkInputReader.pasteboardTypes)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dropRelay.carriesPicture(sender) else { return dropRelay.relayEntered(sender) }
        dropRelay.endRelay()
        dropRing.isHidden = false
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropRelay.isActive ? dropRelay.operation : (dropRelay.carriesPicture(sender) ? .copy : [])
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropRing.isHidden = true
        dropRelay.relayExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropRing.isHidden = true
        dropRelay.relayEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropRing.isHidden = true
        if dropRelay.isActive { return dropRelay.relayPerform(sender) }
        guard let input = ArtworkInputReader.input(from: sender.draggingPasteboard) else { return false }
        onPictureDrop?(input)
        return true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let full = bounds
        customLayer.frame = full
        dropRing.frame = full
        let w = full.width
        let h = full.height
        switch tileLayers.count {
        case 1:
            tileLayers[0].frame = full
        case 2:
            tileLayers[0].frame = CGRect(x: 0, y: 0, width: w / 2, height: h)
            tileLayers[1].frame = CGRect(x: w / 2, y: 0, width: w / 2, height: h)
        case 3:
            tileLayers[0].frame = CGRect(x: 0, y: 0, width: w / 2, height: h)
            tileLayers[1].frame = CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2)
            tileLayers[2].frame = CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2)
        case 4:
            tileLayers[0].frame = CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2)
            tileLayers[1].frame = CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2)
            tileLayers[2].frame = CGRect(x: 0, y: 0, width: w / 2, height: h / 2)
            tileLayers[3].frame = CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2)
        default:
            break
        }
        for tile in tileLayers {
            tile.sublayers?.first?.frame = tile.bounds
        }
    }
}
