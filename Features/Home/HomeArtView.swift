import FlaccyCore
import UIKit

/// Cover art for anything Home lists: one album fills the square, several
/// share it as a mosaic, and a radio with no albums behind it shows its glyph.
final class HomeArtView: UIView {

    private let mosaic: StackedArtworkMosaicView
    private let symbolView = UIImageView()
    private var shownAlbumIDs: [String] = []
    private var shownGlyph: String?
    private var token = UUID()

    init(cornerRadius: CGFloat, showsShadow: Bool = false, placeholderPointSize: CGFloat = 28) {
        mosaic = StackedArtworkMosaicView(
            cornerRadius: cornerRadius, showsShadow: showsShadow, placeholderPointSize: placeholderPointSize
        )
        super.init(frame: .zero)
        mosaic.isAccessibilityElement = false
        mosaic.artworkElement.isAccessibilityElement = false
        mosaic.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mosaic)

        symbolView.contentMode = .center
        symbolView.tintColor = .white
        symbolView.isHidden = true
        symbolView.layer.cornerRadius = cornerRadius
        symbolView.layer.cornerCurve = .continuous
        symbolView.clipsToBounds = true
        symbolView.backgroundColor = UIColor(red: 0.30, green: 0.27, blue: 0.62, alpha: 1)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbolView)

        NSLayoutConstraint.activate([
            mosaic.topAnchor.constraint(equalTo: topAnchor),
            mosaic.leadingAnchor.constraint(equalTo: leadingAnchor),
            mosaic.trailingAnchor.constraint(equalTo: trailingAnchor),
            mosaic.bottomAnchor.constraint(equalTo: bottomAnchor),
            symbolView.topAnchor.constraint(equalTo: topAnchor),
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor),
            symbolView.trailingAnchor.constraint(equalTo: trailingAnchor),
            symbolView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `albums`' covers, or `glyph` on a tinted square when there are
    /// none to show. Asking for what is already on screen changes nothing.
    func show(albums: [Album], glyph: String? = nil) {
        let ids = albums.map(\.id)
        guard ids != shownAlbumIDs || glyph != shownGlyph else { return }
        shownAlbumIDs = ids
        shownGlyph = glyph
        token = UUID()
        let current = token
        guard !albums.isEmpty else {
            mosaic.setCovers([])
            symbolView.isHidden = glyph == nil
            if let glyph {
                let size = max(bounds.height, 56) * 0.34
                symbolView.image = UIImage(
                    systemName: glyph, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
                )
            }
            return
        }
        symbolView.isHidden = true
        let first = albums.map { AlbumArtworkCache.shared.thumbnail(forAlbum: $0.title, artist: $0.artist) }
        if first.allSatisfy({ $0 != nil }) {
            mosaic.setCovers(first.compactMap { $0 })
            return
        }
        loadCovers(of: albums, token: current)
    }

    private func loadCovers(of albums: [Album], token current: UUID) {
        let group = DispatchGroup()
        var loaded = [Int: UIImage]()
        for (index, album) in albums.enumerated() {
            group.enter()
            AlbumArtworkCache.shared.loadThumbnail(forAlbum: album.title, artist: album.artist) { image in
                if let image { loaded[index] = image }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, self.token == current else { return }
            self.mosaic.setCovers(loaded.keys.sorted().compactMap { loaded[$0] })
        }
    }

    func reset() {
        token = UUID()
        shownAlbumIDs = []
        shownGlyph = nil
        mosaic.setCovers([])
        symbolView.isHidden = true
    }
}
