import AppKit

/// One picture on a shelf: a rounded thumbnail with its caption and size, a
/// ring when it is the one in use and a lift under the pointer.
final class ArtworkShelfTile: NSView {

    struct Model {
        let id: String
        let caption: String
        let detail: String?
        let accessibilityLabel: String
    }

    static let imageSide: CGFloat = 96

    var onSelect: ((String) -> Void)?

    let model: Model

    private let imageHost = NSView()
    private let imageLayer = CALayer()
    private let ring = CALayer()
    private let captionLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var isHovering = false

    init(model: Model) {
        self.model = model
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        imageHost.wantsLayer = true
        imageHost.layer?.cornerRadius = 12
        imageHost.layer?.cornerCurve = .continuous
        imageHost.layer?.masksToBounds = true
        imageHost.layer?.backgroundColor = MacColors.onArtwork(0.1).cgColor
        imageHost.translatesAutoresizingMaskIntoConstraints = false
        imageLayer.contentsGravity = .resizeAspectFill
        imageHost.layer?.addSublayer(imageLayer)
        ring.borderColor = NSColor.white.cgColor
        ring.borderWidth = 3
        ring.cornerRadius = 12
        ring.cornerCurve = .continuous
        ring.opacity = 0
        imageHost.layer?.addSublayer(ring)

        captionLabel.stringValue = model.caption
        captionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        captionLabel.textColor = MacColors.onArtwork(0.75)
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.alignment = .center
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.stringValue = model.detail ?? ""
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = MacColors.onArtwork(0.5)
        detailLabel.alignment = .center
        detailLabel.isHidden = model.detail == nil
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageHost)
        addSubview(captionLabel)
        addSubview(detailLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.imageSide),
            imageHost.topAnchor.constraint(equalTo: topAnchor),
            imageHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageHost.heightAnchor.constraint(equalToConstant: Self.imageSide),
            captionLabel.topAnchor.constraint(equalTo: imageHost.bottomAnchor, constant: 6),
            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 1),
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        toolTip = model.caption
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(model.accessibilityLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = imageHost.bounds
        ring.frame = imageHost.bounds
        CATransaction.commit()
    }

    func setImage(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    func setSelected(_ selected: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        ring.opacity = selected ? 1 : 0
        CATransaction.commit()
        setAccessibilityValue(selected ? String(localized: "Selected") : nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        imageHost.animator().alphaValue = 0.85
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        imageHost.animator().alphaValue = 1
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?(model.id) }
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?(model.id)
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// A titled, horizontally scrolling row of pictures with an optional accessory
/// beside the title (a spinner, a count) and a status line for when it is empty
/// or could not be filled.
final class ArtworkShelfView: NSView {

    var onSelect: ((String) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    private let row = NSStackView()
    private var tiles: [String: ArtworkShelfTile] = [:]
    private var selectedID: String?

    static let height: CGFloat = ArtworkShelfTile.imageSide + 44

    init(title: String, controls: NSView? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = MacColors.onArtwork()
        titleLabel.setAccessibilityRole(.staticText)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let header = NSStackView(views: [titleLabel, spinner])
        header.orientation = .horizontal
        header.spacing = 8
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
        row.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(row)
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = MacColors.onArtwork(0.55)
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [header] + (controls.map { [$0] } ?? []) + [scrollView, statusLabel])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: column.widthAnchor),
            controls.map { $0.widthAnchor.constraint(equalTo: column.widthAnchor) } ?? header.widthAnchor.constraint(equalTo: column.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: column.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: Self.height),
            row.topAnchor.constraint(equalTo: document.topAnchor),
            row.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            row.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            row.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])
        showStatus(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var tileCount: Int { tiles.count }

    func setBusy(_ busy: Bool) {
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func showStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
    }

    func setTiles(_ models: [ArtworkShelfTile.Model]) {
        tiles.values.forEach { $0.removeFromSuperview() }
        tiles = [:]
        for model in models {
            let tile = ArtworkShelfTile(model: model)
            tile.onSelect = { [weak self] id in self?.onSelect?(id) }
            tile.setSelected(model.id == selectedID)
            row.addArrangedSubview(tile)
            tiles[model.id] = tile
        }
        scrollView.isHidden = models.isEmpty
        scrollView.contentView.scroll(to: .zero)
    }

    func setImage(_ image: CGImage?, forTile id: String) {
        tiles[id]?.setImage(image)
    }

    func removeTile(_ id: String) {
        guard let tile = tiles.removeValue(forKey: id) else { return }
        tile.removeFromSuperview()
        if tiles.isEmpty { scrollView.isHidden = true }
    }

    func select(_ id: String?) {
        selectedID = id
        for (tileID, tile) in tiles { tile.setSelected(tileID == id) }
    }
}
