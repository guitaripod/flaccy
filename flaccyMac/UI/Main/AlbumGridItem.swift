import AppKit

/// One album tile: rounded artwork (or the family-wide FNV-1a placeholder
/// gradient), title and artist labels, hover lift, quality badge overlay.
final class AlbumGridItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("AlbumGridItem")

    var onDoubleClick: (() -> Void)?

    private let artworkView = NSImageView()
    private let artworkContainer = NSView()
    private let placeholderLayer = CAGradientLayer()
    private let titleLabel = NSTextField(labelWithString: "")
    private let artistLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()
    private var currentAlbumID: String?

    override func loadView() {
        view = AlbumGridItemView(owner: self)
        view.wantsLayer = true

        artworkContainer.wantsLayer = true
        artworkContainer.layer?.cornerRadius = 10
        artworkContainer.layer?.cornerCurve = .continuous
        artworkContainer.layer?.masksToBounds = true
        artworkContainer.translatesAutoresizingMaskIntoConstraints = false

        placeholderLayer.frame = CGRect(x: 0, y: 0, width: 184, height: 184)
        artworkContainer.layer?.addSublayer(placeholderLayer)

        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(artworkView)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        artistLabel.font = .systemFont(ofSize: 12)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.maximumNumberOfLines = 1

        badgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor = .white
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badgeContainer.layer?.cornerRadius = 7
        badgeContainer.layer?.cornerCurve = .continuous
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(badgeLabel)
        artworkContainer.addSubview(badgeContainer)

        let labels = NSStackView(views: [titleLabel, artistLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(artworkContainer)
        view.addSubview(labels)

        NSLayoutConstraint.activate([
            artworkContainer.topAnchor.constraint(equalTo: view.topAnchor),
            artworkContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            artworkContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            artworkContainer.heightAnchor.constraint(equalTo: artworkContainer.widthAnchor),

            artworkView.topAnchor.constraint(equalTo: artworkContainer.topAnchor),
            artworkView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor),
            artworkView.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor),

            badgeContainer.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor, constant: 8),
            badgeContainer.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor, constant: -8),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 6),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -6),
            badgeLabel.topAnchor.constraint(equalTo: badgeContainer.topAnchor, constant: 3),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeContainer.bottomAnchor, constant: -3),

            labels.topAnchor.constraint(equalTo: artworkContainer.bottomAnchor, constant: 8),
            labels.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            labels.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholderLayer.frame = artworkContainer.bounds
        CATransaction.commit()
    }

    func configure(with album: Album) {
        let albumID = album.id
        currentAlbumID = albumID
        titleLabel.stringValue = album.title
        artistLabel.stringValue = album.artist
        titleLabel.toolTip = album.title
        artistLabel.toolTip = album.artist

        let badge = bestQualityBadge(for: album)
        badgeLabel.stringValue = badge ?? ""
        badgeContainer.isHidden = badge == nil

        applyPlaceholder(seed: albumID)
        if let cached = AlbumArtworkCache.shared.thumbnail(forAlbum: album.title, artist: album.artist) {
            showArtwork(cached)
            return
        }
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: album.title, artist: album.artist) { [weak self] image in
            guard let self, self.currentAlbumID == albumID, let image else { return }
            self.showArtwork(image)
        }
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
                : nil
            view.layer?.cornerRadius = 12
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentAlbumID = nil
        artworkView.image = nil
        onDoubleClick = nil
    }

    fileprivate func handleDoubleClick() {
        onDoubleClick?()
    }

    private func showArtwork(_ image: NSImage) {
        artworkView.image = image
        placeholderLayer.isHidden = true
    }

    private func applyPlaceholder(seed: String) {
        artworkView.image = nil
        placeholderLayer.isHidden = false
        let (base, second) = PlaceholderGradient.colors(seed: seed)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholderLayer.colors = [base.cgColor, second.cgColor]
        placeholderLayer.startPoint = CGPoint(x: 0, y: 1)
        placeholderLayer.endPoint = CGPoint(x: 1, y: 0)
        CATransaction.commit()
    }

    private func bestQualityBadge(for album: Album) -> String? {
        let best = album.tracks.max {
            ($0.sampleRate ?? 0, $0.bitDepth ?? 0) < ($1.sampleRate ?? 0, $1.bitDepth ?? 0)
        }
        return best?.qualityBadge
    }
}

private final class AlbumGridItemView: NSView {

    private weak var owner: AlbumGridItem?

    init(owner: AlbumGridItem) {
        self.owner = owner
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            owner?.handleDoubleClick()
        }
    }
}
