import AppKit
import MidgarCore
import FlaccyCore
import UniformTypeIdentifiers

/// The sheet where a person chooses a cover for an album or a playlist: frame the current
/// one, bring their own from a file, the clipboard or a drop, pick a picture
/// that already lies beside the music or sits inside its files, or find a
/// higher-resolution match online. Nothing is written until Save.
final class ArtworkEditorViewController: NSViewController {

    enum Outcome {
        case saved
        case restored
        case cancelled
    }

    var onFinish: ((Outcome) -> Void)?

    private let subject: ArtworkSubject
    private let initialInput: ArtworkInput?
    private let localRoot: URL
    private let hasCustomCover: Bool

    private let root = ArtworkEditorRootView()
    private let backdropLayer = CALayer()
    private let cropView = MacArtworkCropView()
    private let albumPreview = ArtworkFramedView()
    private let listPreview = ArtworkFramedView()
    private let miniPreview = ArtworkFramedView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let softLabel = NSTextField(labelWithString: "")
    private let zoomSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let fitButton = GlassCapsuleButton(title: String(localized: "Fit"), symbolName: "arrow.up.left.and.arrow.down.right")
    private let chooseButton = GlassCapsuleButton(title: String(localized: "Choose File…"), symbolName: "folder")
    private let pasteButton = GlassCapsuleButton(title: String(localized: "Paste"), symbolName: "doc.on.clipboard")
    private let searchField = NSSearchField()
    private let searchButton = GlassCapsuleButton(title: String(localized: "Search"), symbolName: "magnifyingglass")
    private lazy var localShelf = ArtworkShelfView(
        title: subject.isPlaylist ? String(localized: "From This Playlist") : String(localized: "In Your Files")
    )
    private let searchRow = NSStackView()
    private lazy var onlineShelf = ArtworkShelfView(title: String(localized: "Find Online"), controls: searchRow)
    private lazy var resetButton = NSButton(
        title: subject.isPlaylist ? String(localized: "Use Automatic Cover") : String(localized: "Use Original Artwork"),
        target: nil, action: nil
    )
    private let cancelButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)
    private let saveButton = NSButton(title: String(localized: "Save"), target: nil, action: nil)

    private var sourceImage: CGImage?
    private var sourceLabel = ""
    private var hasReplacedImage = false
    private var didApplyCurrentArtwork = false
    private var isSaving = false
    private var localItems: [String: LocalArtworkItem] = [:]
    private var candidates: [String: ArtworkCandidate] = [:]
    private var searchToken = 0
    private var searchTask: Task<Void, Never>?
    private var thumbnailTasks: [Task<Void, Never>] = []
    private var loadTask: Task<Void, Never>?
    private var localTask: Task<Void, Never>?
    private var pasteboardTimer: Timer?
    private var lastPasteboardCount = -1
    private var defaultQuery: String { subject.defaultQuery }

    init(subject: ArtworkSubject, initial: ArtworkInput?, localRoot: URL = LibraryPaths.root) {
        self.subject = subject
        self.initialInput = initial
        self.localRoot = localRoot
        self.hasCustomCover = AlbumArtworkEditor.hasCustomCover(subject)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        pasteboardTimer?.invalidate()
        searchTask?.cancel()
        loadTask?.cancel()
        localTask?.cancel()
        thumbnailTasks.forEach { $0.cancel() }
    }

    override func loadView() {
        let container = NSView()
        let zoomHost = InterfaceZoomHostView(frame: .zero)
        zoomHost.frame = container.bounds
        container.addSubview(zoomHost)
        view = container

        let host = zoomHost.content
        root.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: host.topAnchor),
            root.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        buildBackdrop()
        let header = buildHeader()
        let footer = buildFooter()
        let left = buildLeftColumn()
        let right = buildRightColumn()
        layoutBody(header: header, footer: footer, left: left, right: right)
        wireActions()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        framingChanged(animated: false)
        refreshPasteAvailability()
        loadCurrentArtwork()
        showEmptyPlaylistHint()
        if let initialInput { accept(initialInput) }
        loadLocalPictures()
        runSearch()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(cropView)
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPasteAvailability() }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
    }

    var hasUnsavedChanges: Bool { hasReplacedImage || cropView.hasUserFraming }

    private func buildBackdrop() {
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        backdropLayer.contentsGravity = .resizeAspectFill
        backdropLayer.opacity = 0
        root.layer?.addSublayer(backdropLayer)
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        let scrim = NSView()
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        scrim.translatesAutoresizingMaskIntoConstraints = false
        for overlay in [blur, scrim] {
            root.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: root.topAnchor),
                overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        root.onLayout = { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.backdropLayer.frame = self.root.bounds
            CATransaction.commit()
        }
    }

    private func buildHeader() -> NSView {
        let title = NSTextField(
            labelWithString: subject.isPlaylist ? String(localized: "Playlist Cover") : String(localized: "Artwork")
        )
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = MacColors.onArtwork()
        let subtitle = NSTextField(labelWithString: subject.subtitle)
        subtitle.font = .systemFont(ofSize: 12.5)
        subtitle.textColor = MacColors.onArtwork(0.6)
        subtitle.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        keepTextHeight(title, subtitle)
        root.addSubview(stack)
        return stack
    }

    private func buildFooter() -> NSView {
        resetButton.contentTintColor = .systemRed
        resetButton.isHidden = !hasCustomCover
        resetButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        resetButton.imagePosition = .imageLeading
        resetButton.bezelStyle = .rounded
        cancelButton.bezelStyle = .rounded
        saveButton.bezelStyle = .rounded
        saveButton.bezelColor = .controlAccentColor
        saveButton.isEnabled = false
        saveButton.toolTip = String(localized: "Save (⌘↩)")
        cancelButton.toolTip = String(localized: "Cancel (Esc)")

        let spacer = NSView()
        let stack = NSStackView(views: [resetButton, spacer, cancelButton, saveButton])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        root.addSubview(stack)
        return stack
    }

    private func buildLeftColumn() -> NSView {
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        cropView.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(cropView)

        infoLabel.font = .systemFont(ofSize: 12, weight: .medium)
        infoLabel.textColor = MacColors.onArtwork(0.6)
        infoLabel.lineBreakMode = .byTruncatingTail
        softLabel.font = .systemFont(ofSize: 12, weight: .medium)
        softLabel.textColor = .systemOrange
        softLabel.lineBreakMode = .byTruncatingTail
        softLabel.stringValue = String(localized: "Low resolution — this will look soft on large displays")
        softLabel.isHidden = true
        keepTextHeight(infoLabel, softLabel)

        let zoomOut = iconButton("minus.magnifyingglass", label: String(localized: "Zoom Out"), action: #selector(zoomOutTapped))
        let zoomIn = iconButton("plus.magnifyingglass", label: String(localized: "Zoom In"), action: #selector(zoomInTapped))
        zoomSlider.target = self
        zoomSlider.action = #selector(sliderMoved)
        zoomSlider.isContinuous = true
        zoomSlider.setAccessibilityLabel(String(localized: "Zoom"))
        zoomSlider.setContentHuggingPriority(.init(1), for: .horizontal)
        fitButton.setContentHuggingPriority(.required, for: .horizontal)
        let zoomRow = NSStackView(views: [zoomOut, zoomSlider, zoomIn, fitButton])
        zoomRow.orientation = .horizontal
        zoomRow.spacing = 8
        zoomRow.alignment = .centerY

        let previews = buildPreviews()
        let below = NSStackView(views: [zoomRow, infoLabel, softLabel, previews])
        below.orientation = .vertical
        below.alignment = .leading
        below.spacing = 6
        below.setCustomSpacing(14, after: softLabel)
        below.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(below)

        let fill = cropView.widthAnchor.constraint(equalTo: column.widthAnchor)
        fill.priority = .init(700)
        NSLayoutConstraint.activate([
            cropView.topAnchor.constraint(equalTo: column.topAnchor),
            cropView.centerXAnchor.constraint(equalTo: column.centerXAnchor),
            cropView.heightAnchor.constraint(equalTo: cropView.widthAnchor),
            cropView.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
            cropView.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            cropView.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            fill,
            below.topAnchor.constraint(equalTo: cropView.bottomAnchor, constant: 14),
            below.leadingAnchor.constraint(equalTo: cropView.leadingAnchor),
            below.trailingAnchor.constraint(equalTo: cropView.trailingAnchor),
            below.bottomAnchor.constraint(lessThanOrEqualTo: column.bottomAnchor),
            zoomRow.widthAnchor.constraint(equalTo: below.widthAnchor),
            previews.widthAnchor.constraint(equalTo: below.widthAnchor),
        ])
        return column
    }

    private func buildPreviews() -> NSView {
        let title = NSTextField(labelWithString: String(localized: "Previews"))
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = MacColors.onArtwork(0.5)
        keepTextHeight(title)
        let specs: [(ArtworkFramedView, CGFloat, CGFloat, String)] = [
            (albumPreview, 104, 10, String(localized: "Album tile preview")),
            (listPreview, 44, 6, String(localized: "List row preview")),
            (miniPreview, 30, 5, String(localized: "Mini player preview")),
        ]
        var views: [NSView] = []
        for (preview, side, radius, label) in specs {
            preview.cornerRadius = radius
            preview.translatesAutoresizingMaskIntoConstraints = false
            preview.setAccessibilityElement(true)
            preview.setAccessibilityRole(.image)
            preview.setAccessibilityLabel(label)
            preview.toolTip = label
            NSLayoutConstraint.activate([
                preview.widthAnchor.constraint(equalToConstant: side),
                preview.heightAnchor.constraint(equalToConstant: side),
            ])
            views.append(preview)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .bottom
        row.spacing = 14
        let group = NSStackView(views: [title, row])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        return group
    }

    private func buildRightColumn() -> NSView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: String(localized: "or drop an image here"))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = MacColors.onArtwork(0.5)
        let buttons = MacLiquidGlass.buttonGroup([chooseButton, pasteButton], spacing: 10)
        let sources = NSStackView(views: [buttons, hint])
        sources.orientation = .vertical
        sources.spacing = 6
        sources.alignment = .leading

        searchField.placeholderString = subject.isPlaylist
            ? String(localized: "Search for cover art")
            : String(localized: "Artist and album")
        searchField.stringValue = defaultQuery
        searchField.sendsWholeSearchString = true
        searchField.sendsSearchStringImmediately = false
        searchField.setAccessibilityLabel(String(localized: "Search online covers"))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchRow.setViews([searchField, searchButton], in: .leading)
        searchRow.orientation = .horizontal
        searchRow.spacing = 8
        searchRow.alignment = .centerY
        searchField.setContentHuggingPriority(.init(1), for: .horizontal)

        localShelf.isHidden = true
        let content = NSStackView(views: [sources, localShelf, onlineShelf])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 22
        content.translatesAutoresizingMaskIntoConstraints = false

        let document = DetailDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
            localShelf.widthAnchor.constraint(equalTo: content.widthAnchor),
            onlineShelf.widthAnchor.constraint(equalTo: content.widthAnchor),
            sources.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
        ])
        return scroll
    }

    private func layoutBody(header: NSView, footer: NSView, left: NSView, right: NSView) {
        root.addSubview(left)
        root.addSubview(right)
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rule)
        let leftWidth = left.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.5, constant: -36)
        let leftCap = left.widthAnchor.constraint(lessThanOrEqualToConstant: 660)
        leftCap.priority = .init(900)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),

            left.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            left.bottomAnchor.constraint(equalTo: rule.topAnchor, constant: -14),
            leftWidth,
            leftCap,
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),

            right.topAnchor.constraint(equalTo: left.topAnchor),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 24),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            right.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            right.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),

            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
    }

    /// The preview square wants all the room it can get, but a line of text
    /// must never be the thing that gives way for it: a label squeezed to no
    /// height simply disappears.
    private func keepTextHeight(_ labels: NSTextField...) {
        for label in labels { label.setContentCompressionResistancePriority(.init(900), for: .vertical) }
    }

    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.contentTintColor = MacColors.onArtwork(0.75)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func wireActions() {
        cropView.onFramingChanged = { [weak self] animated in self?.framingChanged(animated: animated) }
        chooseButton.onClick = { [weak self] in self?.chooseFile() }
        pasteButton.onClick = { [weak self] in self?.pasteFromClipboard() }
        fitButton.onClick = { [weak self] in self?.cropView.fit() }
        searchButton.onClick = { [weak self] in self?.runSearch() }
        searchField.target = self
        searchField.action = #selector(searchSubmitted)
        resetButton.target = self
        resetButton.action = #selector(confirmReset)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        saveButton.target = self
        saveButton.action = #selector(save)
        localShelf.onSelect = { [weak self] id in self?.selectLocal(id) }
        onlineShelf.onSelect = { [weak self] id in self?.selectOnline(id) }
        root.onDrop = { [weak self] input in self?.accept(input) }
        root.onChooseFile = { [weak self] in self?.chooseFile() }
        root.onPaste = { [weak self] in self?.pasteFromClipboard() }
        root.onSave = { [weak self] in self?.save() }
    }

    private func framingChanged(animated: Bool) {
        let framing = cropView.framing
        for preview in [albumPreview, listPreview, miniPreview] {
            if preview.image !== cropView.image, let image = cropView.image {
                preview.show(image, framing: framing)
            } else {
                preview.update(framing: framing, animated: animated)
            }
        }
        zoomSlider.doubleValue = framing?.zoomFraction ?? 0
        zoomSlider.isEnabled = framing != nil
        softLabel.isHidden = !(framing?.isSoft ?? false)
        fitButton.isEnabled = framing.map { !isFresh($0) } ?? false
        refreshSaveState()
    }

    private func isFresh(_ framing: ArtworkFraming) -> Bool {
        ArtworkFraming(
            imageWidth: framing.imageWidth, imageHeight: framing.imageHeight, frameSide: framing.frameSide
        ) == framing
    }

    private func refreshSaveState() {
        saveButton.isEnabled = hasUnsavedChanges && cropView.hasImage && !isSaving
    }

    private func refreshPasteAvailability() {
        let count = NSPasteboard.general.changeCount
        guard count != lastPasteboardCount else { return }
        lastPasteboardCount = count
        pasteButton.isEnabled = ArtworkInputReader.input(from: .general) != nil
    }

    private func describe(_ image: CGImage, source: String) -> String {
        "\(source) · \(image.width) × \(image.height)"
    }

    private func setBackdrop(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        backdropLayer.contents = image
        backdropLayer.opacity = 1
        CATransaction.commit()
    }

    private func loadCurrentArtwork() {
        let apply: (PlatformImage?) -> Void = { [weak self] image in
            guard let self, !self.hasReplacedImage, !self.didApplyCurrentArtwork, let cgImage = image?.cgImage else { return }
            self.didApplyCurrentArtwork = true
            self.sourceImage = cgImage
            self.sourceLabel = String(localized: "Current artwork")
            self.cropView.setSource(cgImage, userInitiated: false)
            self.setBackdrop(cgImage)
            self.infoLabel.stringValue = self.describe(cgImage, source: self.sourceLabel)
        }
        let (title, artist) = (subject.cacheTitle, subject.cacheArtist)
        if let cached = AlbumArtworkCache.shared.artwork(forAlbum: title, artist: artist) {
            apply(cached)
        } else {
            AlbumArtworkCache.shared.loadArtwork(forAlbum: title, artist: artist, completion: apply)
        }
    }

    /// A playlist with no chosen picture has no current cover to frame, so the
    /// preview says what to do instead of sitting empty.
    private func showEmptyPlaylistHint() {
        guard subject.isPlaylist, !hasCustomCover, initialInput == nil else { return }
        cropView.setPlaceholderSymbol("music.note.list")
        infoLabel.stringValue = String(localized: "No cover chosen yet")
    }

    private func adopt(_ image: CGImage, source: String) {
        hasReplacedImage = true
        sourceImage = image
        sourceLabel = source
        cropView.setSource(image, userInitiated: true)
        setBackdrop(image)
        infoLabel.stringValue = describe(image, source: source)
        view.window?.makeFirstResponder(cropView)
    }

    private func fail(_ message: String) {
        infoLabel.stringValue = message
        NSSound.beep()
    }

    func accept(_ input: ArtworkInput) {
        loadTask?.cancel()
        onlineShelf.select(nil)
        localShelf.select(nil)
        cropView.setLoading(true)
        loadTask = Task { [weak self] in
            do {
                let loaded = try await ArtworkInputReader.load(input)
                let decoded = await Task.detached { AlbumArtworkEditor.decodeSource(loaded.data) }.value
                guard let self, !Task.isCancelled else { return }
                self.cropView.setLoading(false)
                guard let decoded else {
                    self.fail(String(localized: "That file couldn't be read as an image."))
                    return
                }
                self.adopt(decoded, source: loaded.label)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.cropView.setLoading(false)
                self.fail(Self.message(for: error))
            }
        }
    }

    private static func message(for error: Error) -> String {
        if case ArtworkInputError.tooLarge = error { return String(localized: "That image is too large.") }
        if error is BoundedHTTPSFetcher.Failure || error is URLError {
            return String(localized: "Couldn't download that image. Check your connection and try again.")
        }
        return String(localized: "That file couldn't be read as an image.")
    }

    private func chooseFile() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .webP, .heic, .tiff, .gif, .bmp]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = subject.isPlaylist
                ? String(localized: "Choose an image for this playlist's cover")
                : String(localized: "Choose an image for this album's cover")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.accept(.file(url)) }
        }
    }

    private func pasteFromClipboard() {
        guard let input = ArtworkInputReader.input(from: .general) else {
            NSSound.beep()
            return
        }
        accept(input)
    }

    private func loadLocalPictures() {
        let subject = subject
        guard !subject.isPlaylist else {
            loadPlaylistAlbumCovers()
            return
        }
        let album = subject.album
        let root = localRoot
        localTask = Task { [weak self] in
            let folderItems = await Task.detached { LocalArtworkFinder.folderImages(for: album, root: root) }.value
            guard let self, !Task.isCancelled else { return }
            self.showLocal(folderItems)
            let embedded = await LocalArtworkFinder.embeddedImages(for: album)
            guard !Task.isCancelled else { return }
            self.showLocal(folderItems + embedded)
        }
    }

    /// The covers of the releases the playlist draws from, read from the
    /// database, so the shelf fills at once and offers ready-made choices.
    private func loadPlaylistAlbumCovers() {
        let subject = subject
        localTask = Task { [weak self] in
            let items = await Task.detached { LocalArtworkFinder.playlistAlbumCovers(for: subject) }.value
            guard let self, !Task.isCancelled else { return }
            self.showLocal(items)
        }
    }

    private func showLocal(_ items: [LocalArtworkItem]) {
        localItems = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        localShelf.isHidden = items.isEmpty
        localShelf.setTiles(items.map { item in
            ArtworkShelfTile.Model(
                id: item.id,
                caption: item.label,
                detail: "\(item.pixelWidth)×\(item.pixelHeight)",
                accessibilityLabel: "\(item.label), \(item.pixelWidth) × \(item.pixelHeight)"
            )
        })
        for item in items { localShelf.setImage(item.thumbnail, forTile: item.id) }
    }

    private func selectLocal(_ id: String) {
        guard let item = localItems[id] else { return }
        localShelf.select(id)
        onlineShelf.select(nil)
        loadTask?.cancel()
        cropView.setLoading(true)
        loadTask = Task { [weak self] in
            let decoded = await Task.detached { () -> CGImage? in
                guard let data = try? item.loadData() else { return nil }
                return AlbumArtworkEditor.decodeSource(data)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.cropView.setLoading(false)
            guard let decoded else {
                self.localShelf.select(nil)
                self.fail(String(localized: "That file couldn't be read as an image."))
                return
            }
            self.adopt(decoded, source: item.label)
        }
    }

    @objc private func searchSubmitted() {
        runSearch()
    }

    private func runSearch() {
        searchToken += 1
        let token = searchToken
        searchTask?.cancel()
        thumbnailTasks.forEach { $0.cancel() }
        thumbnailTasks = []
        let query = searchField.stringValue
        if subject.isPlaylist, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showIdleSearch()
            return
        }
        onlineShelf.setBusy(true)
        onlineShelf.showStatus(nil)
        let (title, artist) = searchSubject
        searchTask = Task { [weak self] in
            let result = await OnlineArtworkSearch.lookup(query: query, title: title, artist: artist)
            guard let self, token == self.searchToken, !Task.isCancelled else { return }
            self.onlineShelf.setBusy(false)
            self.showOnline(result, token: token)
        }
    }

    /// A playlist's name matches no catalog entry, so its search waits for
    /// words instead of running on the name.
    private func showIdleSearch() {
        onlineShelf.setBusy(false)
        candidates = [:]
        onlineShelf.setTiles([])
        onlineShelf.showStatus(String(localized: "Type an album or artist and press Return to find cover art."))
    }

    /// What the online providers score results against: the release for an
    /// album, nothing at all for a playlist, whose search is only ever the
    /// person's own words.
    private var searchSubject: (title: String, artist: String) {
        subject.isPlaylist ? ("", "") : (subject.title, subject.credit)
    }

    private func showOnline(_ result: ArtworkSearchResult, token: Int) {
        candidates = Dictionary(result.candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        onlineShelf.setTiles(result.candidates.map { candidate in
            ArtworkShelfTile.Model(
                id: candidate.id,
                caption: candidate.source,
                detail: nil,
                accessibilityLabel: "\(candidate.title), \(candidate.artist), \(candidate.source)"
            )
        })
        guard !result.candidates.isEmpty else {
            onlineShelf.showStatus(Self.emptyStatus(reachedAnyProvider: result.reachedAnyProvider))
            return
        }
        for candidate in result.candidates {
            let task = Task { [weak self] in
                let image = await OnlineArtworkSearch.downloadThumbnail(candidate.thumbnailURL)
                guard let self, token == self.searchToken, !Task.isCancelled else { return }
                guard let cgImage = image?.cgImage else {
                    self.dropOnlineTile(candidate.id)
                    return
                }
                self.onlineShelf.setImage(cgImage, forTile: candidate.id)
            }
            thumbnailTasks.append(task)
        }
    }

    private static func emptyStatus(reachedAnyProvider: Bool) -> String {
        reachedAnyProvider
            ? String(localized: "No matching covers found online")
            : String(localized: "Can't reach the online catalogs. Check your connection.")
    }

    private func dropOnlineTile(_ id: String) {
        onlineShelf.removeTile(id)
        candidates[id] = nil
        if onlineShelf.tileCount == 0 {
            onlineShelf.showStatus(Self.emptyStatus(reachedAnyProvider: true))
        }
    }

    private func selectOnline(_ id: String) {
        guard let candidate = candidates[id] else { return }
        onlineShelf.select(id)
        localShelf.select(nil)
        loadTask?.cancel()
        cropView.setLoading(true)
        infoLabel.stringValue = String(localized: "Loading \(candidate.source) cover…")
        loadTask = Task { [weak self] in
            do {
                let image = try await OnlineArtworkSearch.download(candidate.fullURL)
                guard let self, !Task.isCancelled else { return }
                self.cropView.setLoading(false)
                guard let cgImage = image.cgImage else { throw URLError(.cannotDecodeContentData) }
                self.adopt(cgImage, source: candidate.source)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.cropView.setLoading(false)
                self.onlineShelf.select(nil)
                self.infoLabel.stringValue = String(localized: "Couldn't download that cover. Check your connection and try another.")
                NSSound.beep()
            }
        }
    }

    @objc private func sliderMoved() {
        cropView.setZoomFraction(zoomSlider.doubleValue)
    }

    @objc private func zoomInTapped() {
        cropView.zoom(byFactor: 1.1)
    }

    @objc private func zoomOutTapped() {
        cropView.zoom(byFactor: 1 / 1.1)
    }

    @objc private func save() {
        guard saveButton.isEnabled, let image = sourceImage, let framing = cropView.framing else { return }
        isSaving = true
        refreshSaveState()
        cropView.setLoading(true)
        let subject = subject
        Task { [weak self] in
            do {
                let data = try await Task.detached { () throws -> Data in
                    guard let data = AlbumArtworkEditor.render(image, framing: framing) else { throw ArtworkInputError.unreadable }
                    try AlbumArtworkEditor.save(data, for: subject)
                    return data
                }.value
                MidgarLog.info("Artwork editor saved \(data.count / 1024) KB", category: .ui)
                self?.onFinish?(.saved)
            } catch {
                MidgarLog.error("Saving cover failed: \(error.localizedDescription)", category: .database)
                guard let self else { return }
                self.isSaving = false
                self.cropView.setLoading(false)
                self.refreshSaveState()
                if case ArtworkInputError.unreadable = error {
                    self.fail(String(localized: "Couldn't save the artwork — the framed picture couldn't be rendered. Choose a different image."))
                } else {
                    self.fail(String(localized: "Couldn't save the artwork — the library database couldn't be written. Check free disk space and try again."))
                }
            }
        }
    }

    @objc private func cancelTapped() {
        requestCancel()
    }

    override func cancelOperation(_ sender: Any?) {
        requestCancel()
    }

    func requestCancel() {
        guard hasUnsavedChanges, let window = view.window else {
            onFinish?(.cancelled)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard your changes?")
        alert.informativeText = String(localized: "The cover you framed has not been saved.")
        alert.addButton(withTitle: String(localized: "Discard Changes")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Keep Editing"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.onFinish?(.cancelled) }
        }
    }

    @objc private func confirmReset() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        if subject.isPlaylist {
            alert.messageText = String(localized: "Use the automatic cover?")
            alert.informativeText = String(localized: "Your chosen picture will be removed and the playlist goes back to a mosaic of its albums.")
            alert.addButton(withTitle: String(localized: "Use Automatic Cover")).hasDestructiveAction = true
        } else {
            alert.messageText = String(localized: "Use the original artwork?")
            alert.informativeText = String(localized: "Your chosen cover will be removed and the artwork from the music files is used again.")
            alert.addButton(withTitle: String(localized: "Use Original")).hasDestructiveAction = true
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.performReset() }
        }
    }

    private func performReset() {
        let subject = subject
        Task { [weak self] in
            do {
                try await Task.detached { try AlbumArtworkEditor.reset(subject) }.value
                self?.onFinish?(.restored)
            } catch {
                MidgarLog.error("Resetting cover failed: \(error.localizedDescription)", category: .database)
                self?.fail(subject.isPlaylist
                    ? String(localized: "Couldn't restore the automatic cover — the library database couldn't be written. Check free disk space and try again.")
                    : String(localized: "Couldn't restore the original artwork — the library database couldn't be written. Check free disk space and try again."))
            }
        }
    }

    #if DEBUG
    func debugAdopt(_ image: CGImage, source: String) {
        adopt(image, source: source)
    }

    func debugFrame(zoomFraction: Double, anchor: CGPoint) {
        guard let framing = cropView.framing else { return }
        cropView.debugApply(framing.zoomed(to: framing.fillZoom * (1 + zoomFraction), anchorX: anchor.x, anchorY: anchor.y))
    }

    func debugSearch(_ query: String) {
        searchField.stringValue = query
        runSearch()
    }

    func debugSave() {
        save()
    }

    var debugSaveEnabled: Bool { saveButton.isEnabled }
    var debugSoftLabelVisible: Bool { !softLabel.isHidden }
    var debugLocalTileCount: Int { localShelf.tileCount }
    var debugOnlineTileCount: Int { onlineShelf.tileCount }
    var debugCropImageSize: CGSize { cropView.image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
    #endif
}

/// The editor's root: a drop target for pictures anywhere on the sheet, and the
/// owner of the key equivalents that belong to the sheet rather than to any
/// one control.
final class ArtworkEditorRootView: NSView {

    var onDrop: ((ArtworkInput) -> Void)?
    var onChooseFile: (() -> Void)?
    var onPaste: (() -> Void)?
    var onSave: (() -> Void)?
    var onLayout: (() -> Void)?

    private let highlight = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ArtworkInputReader.pasteboardTypes)
        highlight.wantsLayer = true
        highlight.layer?.borderColor = NSColor.controlAccentColor.cgColor
        highlight.layer?.borderWidth = 3
        highlight.layer?.cornerRadius = 12
        highlight.layer?.cornerCurve = .continuous
        highlight.isHidden = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ArtworkInputReader.input(from: sender.draggingPasteboard) != nil else { return [] }
        highlight.isHidden = false
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlight.isHidden = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        highlight.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight.isHidden = true
        guard let input = ArtworkInputReader.input(from: sender.draggingPasteboard) else { return false }
        onDrop?(input)
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "o":
            onChooseFile?()
        case "v":
            guard !(window?.firstResponder is NSText) else { return false }
            onPaste?()
        case "\r":
            onSave?()
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
