import AppKit

extension Notification.Name {
    /// Posted whenever the now-playing artwork palette changes, so any surface
    /// can retint itself to the color of what's currently playing.
    static let flaccyNowPlayingPaletteChanged = Notification.Name("flaccy.mac.nowPlayingPaletteChanged")
}

/// App-wide source of truth for the color of what's playing. On every track
/// change it extracts the dominant palette from the current cover (falling back
/// to a deterministic seed when there's no art) and broadcasts it, so the whole
/// window can breathe the now-playing color — not just the detail pages.
@MainActor
final class NowPlayingPaletteService: NSObject {

    static let shared = NowPlayingPaletteService()

    private(set) var current: ArtworkPalette = ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy")
    private var currentKey: String?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(trackChanged), name: AudioPlayer.trackDidChange, object: nil
        )
        refresh()
    }

    /// No-op that forces the singleton to instantiate and begin observing.
    func start() {}

    @objc private func trackChanged() { refresh() }

    private func refresh() {
        guard let track = AudioPlayer.shared.currentTrack else {
            currentKey = "flaccy-idle"
            update(ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy"))
            return
        }
        let key = "\(track.albumTitle)\u{0}\(track.artist)"
        guard key != currentKey else { return }
        currentKey = key
        let seed = "\(track.albumTitle)|\(track.artist)"
        if let image = track.artwork
            ?? AlbumArtworkCache.shared.thumbnail(forAlbum: track.albumTitle, artist: track.artist) {
            extract(image: image, key: key, seed: seed)
        } else {
            AlbumArtworkCache.shared.loadArtwork(forAlbum: track.albumTitle, artist: track.artist) { [weak self] image in
                self?.extract(image: image, key: key, seed: seed)
            }
        }
    }

    private func extract(image: PlatformImage?, key: String, seed: String) {
        ArtworkPaletteExtractor.palette(for: image, cacheKey: "np-\(key)", fallbackSeed: seed) { [weak self] palette in
            guard let self, self.currentKey == key else { return }
            self.update(palette)
        }
    }

    private func update(_ palette: ArtworkPalette) {
        guard palette != current else { return }
        current = palette
        NotificationCenter.default.post(name: .flaccyNowPlayingPaletteChanged, object: nil)
    }
}
