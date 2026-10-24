import AppKit

/// One album tile: shimmering artwork (or the family-wide FNV-1a placeholder
/// gradient), quality pill and loved-heart overlays, hover lift and press
/// states, title/artist labels, double-click to play and a context menu.
final class AlbumGridItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("AlbumGridItem")

    var onDoubleClick: (() -> Void)?
    var onOpen: (() -> Void)?
    var onMenu: (() -> NSMenu?)?

    private let artworkTile = ArtworkTileView()
    private let shadowWrap = NSView()
    private let titleLabel = ClickableLabel()
    private let artistLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeContainer = NSView()
    private let lovedHeart = NSImageView()
    private var currentAlbumID: String?
    private var currentAlbum: Album?
    private var artworkObserver: ArtworkChangeObserver?
    private var isHovering = false
    private var isDropTargeted = false

    override func viewWillLayout() {
        super.viewWillLayout()
        updateShadowPath()
    }

    override func loadView() {
        view = AlbumGridItemView(owner: self)
        view.wantsLayer = true

        shadowWrap.wantsLayer = true
        shadowWrap.layer?.shadowColor = NSColor.black.cgColor
        shadowWrap.layer?.shadowOpacity = 0.22
        shadowWrap.layer?.shadowRadius = 6
        shadowWrap.layer?.shadowOffset = CGSize(width: 0, height: -3)
        shadowWrap.translatesAutoresizingMaskIntoConstraints = false

        artworkTile.translatesAutoresizingMaskIntoConstraints = false
        shadowWrap.addSubview(artworkTile)

        badgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor = MacColors.onArtwork()
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badgeContainer.layer?.cornerRadius = 7
        badgeContainer.layer?.cornerCurve = .continuous
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.addSubview(badgeLabel)
        artworkTile.addSubview(badgeContainer)

        lovedHeart.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: String(localized: "Loved"))
        lovedHeart.symbolConfiguration = .init(pointSize: 11, weight: .bold)
        lovedHeart.contentTintColor = NSColor(red: 1, green: 0.28, blue: 0.42, alpha: 1)
        lovedHeart.wantsLayer = true
        lovedHeart.layer?.shadowColor = NSColor.black.cgColor
        lovedHeart.layer?.shadowOpacity = 0.6
        lovedHeart.layer?.shadowRadius = 3
        lovedHeart.layer?.shadowOffset = .zero
        lovedHeart.translatesAutoresizingMaskIntoConstraints = false
        artworkTile.addSubview(lovedHeart)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.onClick = { [weak self] in self?.onOpen?() }

        artistLabel.font = .systemFont(ofSize: 12)
        artistLabel.textColor = .secondaryLabelColor
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.maximumNumberOfLines = 1

        let labels = NSStackView(views: [titleLabel, artistLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(shadowWrap)
        view.addSubview(labels)

        NSLayoutConstraint.activate([
            shadowWrap.topAnchor.constraint(equalTo: view.topAnchor),
            shadowWrap.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shadowWrap.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shadowWrap.heightAnchor.constraint(equalTo: shadowWrap.widthAnchor),

            artworkTile.topAnchor.constraint(equalTo: shadowWrap.topAnchor),
            artworkTile.leadingAnchor.constraint(equalTo: shadowWrap.leadingAnchor),
            artworkTile.trailingAnchor.constraint(equalTo: shadowWrap.trailingAnchor),
            artworkTile.bottomAnchor.constraint(equalTo: shadowWrap.bottomAnchor),

            badgeContainer.leadingAnchor.constraint(equalTo: artworkTile.leadingAnchor, constant: 8),
            badgeContainer.bottomAnchor.constraint(equalTo: artworkTile.bottomAnchor, constant: -8),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor, constant: 6),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.trailingAnchor, constant: -6),
            badgeLabel.topAnchor.constraint(equalTo: badgeContainer.topAnchor, constant: 3),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeContainer.bottomAnchor, constant: -3),

            lovedHeart.trailingAnchor.constraint(equalTo: artworkTile.trailingAnchor, constant: -8),
            lovedHeart.bottomAnchor.constraint(equalTo: artworkTile.bottomAnchor, constant: -8),

            labels.topAnchor.constraint(equalTo: shadowWrap.bottomAnchor, constant: 8),
            labels.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            labels.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
        ])
    }

    func configure(with album: Album, loved: Bool) {
        let albumID = album.id
        currentAlbumID = albumID
        currentAlbum = album
        if artworkObserver == nil {
            artworkObserver = ArtworkChangeObserver { [weak self] in self?.refreshArtwork() }
        }
        titleLabel.stringValue = album.title
        artistLabel.stringValue = album.artist
        titleLabel.toolTip = album.title
        artistLabel.toolTip = album.artist

        let badge = DetailChip.albumQualitySummary(tracks: album.tracks)
        badgeLabel.stringValue = badge ?? ""
        badgeContainer.isHidden = badge == nil
        lovedHeart.isHidden = !loved

        if let cached = AlbumArtworkCache.shared.thumbnail(forAlbum: album.title, artist: album.artist) {
            artworkTile.showImage(cached)
            return
        }
        artworkTile.showPlaceholder(seed: albumID, shimmering: true)
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: album.title, artist: album.artist) { [weak self] image in
            guard let self, self.currentAlbumID == albumID else { return }
            if let image {
                self.artworkTile.showImage(image)
            } else {
                self.artworkTile.stopShimmer()
            }
        }
    }

    /// Reloads this tile's cover after the person changed one, leaving the old
    /// picture up until the new one has decoded. Only a tile showing an album
    /// pays for it, and every other album's thumbnail is still in the cache.
    private func refreshArtwork() {
        guard let album = currentAlbum, let albumID = currentAlbumID else { return }
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: album.title, artist: album.artist) { [weak self] image in
            guard let self, self.currentAlbumID == albumID else { return }
            if let image {
                self.artworkTile.showImage(image)
            } else {
                self.artworkTile.showPlaceholder(seed: albumID, shimmering: false)
            }
        }
    }

    #if DEBUG
    var debugShownImage: CGImage? { artworkTile.displayedImage }
    var debugShadowPath: CGPath? { shadowWrap.layer?.shadowPath }
    #endif

    func setDropTargeted(_ targeted: Bool) {
        isDropTargeted = targeted
        applyBorder()
    }

    private func applyBorder() {
        artworkTile.layer?.borderWidth = isSelected || isDropTargeted ? 2.5 : 0
        artworkTile.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    func setLoved(_ loved: Bool) {
        lovedHeart.isHidden = !loved
    }

    override var isSelected: Bool {
        didSet { applyBorder() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentAlbumID = nil
        currentAlbum = nil
        isDropTargeted = false
        isHovering = false
        applyScale(1)
        onDoubleClick = nil
        onOpen = nil
        onMenu = nil
    }

    fileprivate func handleDoubleClick() {
        onDoubleClick?()
    }

    fileprivate func handleHover(_ hovering: Bool) {
        isHovering = hovering
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        applyScale(hovering ? 1.03 : 1)
        shadowWrap.layer?.shadowOpacity = hovering ? 0.38 : 0.22
    }

    fileprivate func handlePress(_ pressed: Bool) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        applyScale(pressed ? 0.97 : (isHovering ? 1.03 : 1))
    }

    fileprivate func updateShadowPath() {
        guard let layer = shadowWrap.layer, !shadowWrap.bounds.isEmpty else { return }
        layer.shadowPath = CGPath(
            roundedRect: shadowWrap.bounds,
            cornerWidth: artworkTile.cornerRadius,
            cornerHeight: artworkTile.cornerRadius,
            transform: nil
        )
    }

    fileprivate func contextMenu() -> NSMenu? {
        onMenu?()
    }

    private func applyScale(_ scale: CGFloat) {
        guard let layer = shadowWrap.layer else { return }
        let bounds = shadowWrap.bounds
        var transform = CATransform3DMakeTranslation(
            bounds.width * (1 - scale) / 2, bounds.height * (1 - scale) / 2, 0
        )
        transform = CATransform3DScale(transform, scale, scale, 1)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.allowsImplicitAnimation = true
            layer.transform = transform
        }
    }
}

private final class AlbumGridItemView: NSView {

    private weak var owner: AlbumGridItem?

    init(owner: AlbumGridItem) {
        self.owner = owner
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        owner?.updateShadowPath()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        owner?.handleHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        owner?.handleHover(false)
    }

    override func mouseDown(with event: NSEvent) {
        owner?.handlePress(true)
        super.mouseDown(with: event)
        owner?.handlePress(false)
        if event.clickCount == 2 {
            owner?.handleDoubleClick()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.contextMenu() ?? super.menu(for: event)
    }
}

/// Label that opens its album on click, signalled with a pointing-hand cursor.
private final class ClickableLabel: NSTextField {

    var onClick: (() -> Void)?

    convenience init() {
        self.init(labelWithString: "")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1 {
            onClick?()
        } else {
            super.mouseDown(with: event)
        }
    }
}
