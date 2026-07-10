import AppKit

/// Playlist cover art: up to four distinct album covers composed as a 2x2
/// mosaic (three → large-plus-column, two → halves, one → full bleed), with
/// the placeholder gradient standing in for missing covers.
final class MosaicArtworkView: NSView {

    private var tileLayers: [CALayer] = []
    private var currentKey: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with tracks: [Track], fallbackSeed: String) {
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
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let full = bounds
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
