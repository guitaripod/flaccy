import Combine
import MidgarCore
import FlaccyCore
import UIKit
import UniformTypeIdentifiers

final class ListArtworkCell: UICollectionViewListCell {
    var currentArtworkKey: String?

    override func prepareForReuse() {
        super.prepareForReuse()
        currentArtworkKey = nil
    }
}

/// Maps library files to their tracks so a playlist's cover and editor can
/// name the albums it draws from without a database read per file. The map is
/// rebuilt when the library's size changes or on `invalidate()`.
final class PlaylistAlbumIndex {

    var tracksByURL: [URL: Track] = [:]
    var indexedCount = -1

    func invalidate() {
        indexedCount = -1
    }

    func refreshIfNeeded() {
        let all = Library.shared.allTracks
        guard all.count != indexedCount else { return }
        tracksByURL = Dictionary(all.map { ($0.fileURL, $0) }, uniquingKeysWith: { first, _ in first })
        indexedCount = all.count
    }

    func tracks(forPlaylist id: Int64) async -> [Track] {
        refreshIfNeeded()
        let lookup = tracksByURL
        let root = LibraryPaths.root
        return await Task.detached(priority: .userInitiated) {
            let records = (try? DatabaseManager.shared.fetchPlaylistTracks(playlistId: id)) ?? []
            return records.compactMap { lookup[root.appendingPathComponent($0.trackFileURL)] }
        }.value
    }

    func albumKeys(forPlaylist id: Int64) async -> [(title: String, artist: String)] {
        let tracks = await tracks(forPlaylist: id)
        return PlaylistCover.mosaicAlbums(tracks.map { (title: $0.albumTitle, artist: $0.artist) })
    }
}

/// A playlist row's leading thumbnail: the picture the person chose, else a
/// small mosaic of the playlist's first albums laid out like the detail page's
/// cover, else a placeholder. Loads are generation-checked, so a cell that was
/// reused while one was in flight never receives it.
final class PlaylistThumbnailView: UIView {

    static let side = CGSize(width: 52, height: 52)

    let mosaic = StackedArtworkMosaicView(cornerRadius: 8, showsShadow: false, placeholderPointSize: 22)
    var generation = 0

    override init(frame: CGRect) {
        super.init(frame: CGRect(origin: .zero, size: Self.side))
        isAccessibilityElement = false
        mosaic.isAccessibilityElement = false
        mosaic.artworkElement.isAccessibilityElement = false
        mosaic.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mosaic)
        NSLayoutConstraint.activate([
            mosaic.topAnchor.constraint(equalTo: topAnchor),
            mosaic.leadingAnchor.constraint(equalTo: leadingAnchor),
            mosaic.trailingAnchor.constraint(equalTo: trailingAnchor),
            mosaic.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.side.width),
            heightAnchor.constraint(equalToConstant: Self.side.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { Self.side }

    func reset() {
        generation += 1
        mosaic.setCovers([])
    }

    func load(playlistId: Int64, index: PlaylistAlbumIndex) {
        generation += 1
        let current = generation
        AlbumArtworkCache.shared.loadThumbnail(
            forAlbum: PlaylistCover.title(forPlaylist: playlistId), artist: PlaylistCover.artist
        ) { [weak self] custom in
            guard let self, self.generation == current else { return }
            if let custom {
                self.mosaic.setCovers([custom])
                return
            }
            Task { [weak self] in
                let keys = await index.albumKeys(forPlaylist: playlistId)
                self?.loadAlbumThumbnails(keys, generation: current)
            }
        }
    }

    func loadAlbumThumbnails(_ keys: [(title: String, artist: String)], generation current: Int) {
        guard generation == current else { return }
        guard !keys.isEmpty else {
            mosaic.setCovers([])
            return
        }
        var coversByIndex = [Int: UIImage]()
        var remaining = keys.count
        for (position, key) in keys.enumerated() {
            AlbumArtworkCache.shared.loadThumbnail(forAlbum: key.title, artist: key.artist) { [weak self] image in
                guard let self, self.generation == current else { return }
                if let image { coversByIndex[position] = image }
                remaining -= 1
                if remaining == 0 {
                    self.mosaic.setCovers(keys.indices.compactMap { coversByIndex[$0] })
                }
            }
        }
    }
}

final class PlaylistListCell: UICollectionViewListCell {

    let thumbnail = PlaylistThumbnailView()

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.reset()
    }
}
