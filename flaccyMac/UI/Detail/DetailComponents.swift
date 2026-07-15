import AppKit

/// Glass metadata pills for the dark detail headers — the AppKit counterpart
/// of the iOS DetailChip capsules.
enum MacDetailChip {

    static func pill(text: String, systemImage: String?) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = .white

        var views: [NSView] = []
        if let systemImage {
            let icon = NSImageView(image: NSImage(
                systemSymbolName: systemImage, accessibilityDescription: nil
            ) ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            icon.contentTintColor = .white
            views.append(icon)
        }
        views.append(label)

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

        let host = MacLiquidGlass.surface(hosting: stack, cornerRadius: 14)
        host.setAccessibilityLabel(text)
        return host
    }

    static func row(_ chips: [NSView]) -> NSStackView {
        let stack = NSStackView(views: chips)
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }
}

/// One track line inside album detail: number or playing indicator, title,
/// hover-revealed loved heart, duration, hover highlight, double-click plays.
final class DetailTrackRowView: NSView {

    var onDoubleClick: (() -> Void)?
    var onToggleLove: (() -> Void)?
    var onMenu: (() -> NSMenu?)?

    private let numberLabel = NSTextField(labelWithString: "")
    private let playingIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let heartButton = NSButton()
    private let durationLabel = NSTextField(labelWithString: "")
    private var isHovered = false
    private var loved = false
    private var isPlaying = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous

        numberLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        numberLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        numberLabel.alignment = .right

        playingIcon.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Now playing")
        playingIcon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        playingIcon.contentTintColor = .white
        playingIcon.isHidden = true

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail

        heartButton.isBordered = false
        heartButton.imagePosition = .imageOnly
        heartButton.target = self
        heartButton.action = #selector(heartClicked)

        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationLabel.textColor = NSColor.white.withAlphaComponent(0.55)

        for view in [numberLabel, playingIcon, titleLabel, heartButton, durationLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),
            numberLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            numberLabel.widthAnchor.constraint(equalToConstant: 24),
            numberLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            playingIcon.centerXAnchor.constraint(equalTo: numberLabel.centerXAnchor),
            playingIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: heartButton.leadingAnchor, constant: -8),
            heartButton.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -12),
            heartButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            durationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            durationLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(number: Int, title: String, duration: TimeInterval, loved: Bool, isPlaying: Bool) {
        numberLabel.stringValue = "\(number)"
        numberLabel.isHidden = isPlaying
        playingIcon.isHidden = !isPlaying
        titleLabel.stringValue = title
        titleLabel.toolTip = title
        titleLabel.font = .systemFont(ofSize: 13, weight: isPlaying ? .semibold : .regular)
        durationLabel.stringValue = PlaybackFormat.duration(duration)
        self.isPlaying = isPlaying
        self.loved = loved
        refreshHeart()
    }

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        numberLabel.isHidden = playing
        playingIcon.isHidden = !playing
        titleLabel.font = .systemFont(ofSize: 13, weight: playing ? .semibold : .regular)
    }

    func setLoved(_ loved: Bool) {
        guard loved != self.loved else { return }
        self.loved = loved
        refreshHeart()
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
        isHovered = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
        refreshHeart()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = nil
        refreshHeart()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            onDoubleClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu?() ?? super.menu(for: event)
    }

    @objc private func heartClicked() {
        onToggleLove?()
    }

    private func refreshHeart() {
        heartButton.isHidden = !loved && !isHovered
        heartButton.image = NSImage(
            systemSymbolName: loved ? "heart.fill" : "heart",
            accessibilityDescription: loved ? "Unlove" : "Love"
        )
        heartButton.contentTintColor = loved
            ? NSColor(red: 1, green: 0.28, blue: 0.42, alpha: 1)
            : NSColor.white.withAlphaComponent(0.5)
    }
}

/// Horizontal shelf of circular similar-artist bubbles that exist in the
/// local library, shared by both detail screens.
final class SimilarArtistsRowView: NSView {

    var onSelectArtist: ((String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Similar Artists in Your Library")
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        stack.orientation = .horizontal
        stack.spacing = 18
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(artist: String) {
        Task { [weak self] in
            let similar = await SimilarArtistService.shared.similarArtistsInLibrary(toArtist: artist)
            guard let self else { return }
            self.populate(names: similar.prefix(8).map(\.name))
        }
    }

    private func populate(names: [String]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !names.isEmpty else {
            isHidden = true
            return
        }
        isHidden = false
        for name in names {
            let bubble = ArtistBubbleView(name: name)
            bubble.onClick = { [weak self] in self?.onSelectArtist?(name) }
            stack.addArrangedSubview(bubble)
        }
    }
}

private final class ArtistBubbleView: NSView {

    var onClick: (() -> Void)?

    private let tile = ArtworkTileView()
    private let label = NSTextField(labelWithString: "")

    init(name: String) {
        super.init(frame: .zero)

        tile.cornerRadius = 32
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.showPlaceholder(seed: name, shimmering: false)

        label.stringValue = name
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tile)
        addSubview(label)
        NSLayoutConstraint.activate([
            tile.topAnchor.constraint(equalTo: topAnchor),
            tile.centerXAnchor.constraint(equalTo: centerXAnchor),
            tile.widthAnchor.constraint(equalToConstant: 64),
            tile.heightAnchor.constraint(equalToConstant: 64),
            label.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: 76),
        ])

        Task { [weak self] in
            if let photo = await MacArtistImageService.shared.image(for: name) {
                self?.tile.showImage(photo)
            } else if let album = Library.shared.albums.first(where: { $0.artist == name }) {
                AlbumArtworkCache.shared.loadThumbnail(forAlbum: album.title, artist: album.artist) { [weak self] image in
                    if let image { self?.tile.showImage(image) }
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Flipped document view so scroll content lays out top-down.
final class DetailDocumentView: NSView {
    override var isFlipped: Bool { true }
}
