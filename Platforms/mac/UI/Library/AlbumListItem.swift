import AppKit

/// What the Albums page asks of whichever item shows an album, so a tile and
/// a row are driven the same way.
@MainActor
protocol AlbumCollectionItem: NSCollectionViewItem {
    var onDoubleClick: (() -> Void)? { get set }
    var onOpen: (() -> Void)? { get set }
    var onMenu: (() -> NSMenu?)? { get set }
    func configure(with album: Album, loved: Bool)
    func setLoved(_ loved: Bool)
    func setDropTargeted(_ targeted: Bool)
}

/// One album as a row of the Albums list: its cover, title and artist, and at
/// the far end its year, how many songs it holds and how long it runs.
final class AlbumListItem: NSCollectionViewItem, AlbumCollectionItem {

    static let identifier = NSUserInterfaceItemIdentifier("AlbumListItem")
    static let rowHeight: CGFloat = 60

    var onDoubleClick: (() -> Void)?
    var onOpen: (() -> Void)?
    var onMenu: (() -> NSMenu?)?

    private let artworkTile = ArtworkTileView()
    private let titleLabel = ClickableLabel()
    private let artistLabel = NSTextField(labelWithString: "")
    private let factsLabel = NSTextField(labelWithString: "")
    private let lovedHeart = NSImageView()
    private var currentAlbumID: String?
    private var currentAlbum: Album?
    private var artworkObserver: ArtworkChangeObserver?
    private var isHovering = false
    private var isDropTargeted = false

    override func loadView() {
        let row = AlbumListRowView(owner: self)
        row.wantsLayer = true
        row.layer?.themedCornerRadius = 8
        row.layer?.cornerCurve = .continuous
        view = row

        artworkTile.cornerRadius = 6
        artworkTile.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.onClick = { [weak self] in self?.onOpen?() }
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        artistLabel.font = .systemFont(ofSize: 12)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.maximumNumberOfLines = 1
        artistLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        factsLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        factsLabel.textColor = .tertiaryLabelColor
        factsLabel.alignment = .right
        factsLabel.setContentHuggingPriority(.required, for: .horizontal)
        factsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        lovedHeart.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: String(localized: "Loved"))
        lovedHeart.symbolConfiguration = .init(pointSize: 10, weight: .bold)
        lovedHeart.contentTintColor = NSColor(red: 1, green: 0.28, blue: 0.42, alpha: 1)
        lovedHeart.setContentHuggingPriority(.required, for: .horizontal)

        let names = NSStackView(views: [titleLabel, artistLabel])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 2

        let line = NSStackView(views: [artworkTile, names, NSView(), lovedHeart, factsLabel])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 12
        line.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(line)

        NSLayoutConstraint.activate([
            artworkTile.widthAnchor.constraint(equalToConstant: 44),
            artworkTile.heightAnchor.constraint(equalToConstant: 44),
            line.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            line.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    func configure(with album: Album, loved: Bool) {
        let albumID = album.id
        currentAlbumID = albumID
        currentAlbum = album
        if artworkObserver == nil {
            artworkObserver = ArtworkChangeObserver { [weak self] in self?.loadArtwork(shimmering: false) }
        }
        titleLabel.stringValue = album.title
        artistLabel.stringValue = album.artist
        titleLabel.toolTip = album.title
        factsLabel.stringValue = AlbumFacts.line(for: album)
        lovedHeart.isHidden = !loved
        view.setAccessibilityLabel("\(album.title), \(album.artist)")
        if let cached = AlbumArtworkCache.shared.thumbnail(forAlbum: album.title, artist: album.artist) {
            artworkTile.showImage(cached)
            return
        }
        loadArtwork(shimmering: true)
    }

    private func loadArtwork(shimmering: Bool) {
        guard let album = currentAlbum, let albumID = currentAlbumID else { return }
        if shimmering { artworkTile.showPlaceholder(seed: albumID, shimmering: true) }
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: album.title, artist: album.artist) { [weak self] image in
            guard let self, self.currentAlbumID == albumID else { return }
            if let image {
                self.artworkTile.showImage(image)
            } else {
                self.artworkTile.showPlaceholder(seed: albumID, shimmering: false)
            }
        }
    }

    func setLoved(_ loved: Bool) {
        lovedHeart.isHidden = !loved
    }

    func setDropTargeted(_ targeted: Bool) {
        isDropTargeted = targeted
        paint()
    }

    override var isSelected: Bool {
        didSet { paint() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentAlbumID = nil
        currentAlbum = nil
        isDropTargeted = false
        isHovering = false
        onDoubleClick = nil
        onOpen = nil
        onMenu = nil
        paint()
    }

    /// Fills the row for what is happening to it: the accent under a selected
    /// row or one a picture is held over, a faint veil under the pointer.
    fileprivate func paint() {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill: NSColor =
                if isSelected || isDropTargeted {
                    NSColor.flaccyAccent.withAlphaComponent(0.24)
                } else if isHovering {
                    MacColors.fill(0.07)
                } else {
                    .clear
                }
            view.layer?.backgroundColor = fill.cgColor
        }
    }

    fileprivate func handleHover(_ hovering: Bool) {
        isHovering = hovering
        paint()
    }

    fileprivate func handleDoubleClick() {
        onDoubleClick?()
    }

    fileprivate func contextMenu() -> NSMenu? {
        onMenu?()
    }
}

/// What an album's row says at its far end.
enum AlbumFacts {

    /// The year when the album has one, then how many songs and how long.
    static func line(for album: Album) -> String {
        var parts: [String] = []
        if let year = album.year, !year.isEmpty { parts.append(year) }
        parts.append(String(localized: "\(album.tracks.count) songs"))
        let seconds = album.tracks.reduce(0) { $0 + $1.duration }
        if seconds >= 60 {
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
            formatter.unitsStyle = .abbreviated
            if let length = formatter.string(from: seconds) { parts.append(length) }
        }
        return parts.joined(separator: " · ")
    }
}

private final class AlbumListRowView: NSView {

    private weak var owner: AlbumListItem?

    init(owner: AlbumListItem) {
        self.owner = owner
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        owner?.paint()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        owner?.handleHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        owner?.handleHover(false)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            owner?.handleDoubleClick()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.contextMenu() ?? super.menu(for: event)
    }
}
