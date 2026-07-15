import AppKit
import AVFoundation
import Combine

/// The acquisition queue: filter chips over sectioned suggestions from
/// WantlistViewModel — album grids for release/history/discovery sections and
/// detail rows for gaps, upgrades, tracks, and artists. Rows offer Got It,
/// Dismiss, 30-second previews (pausing and resuming main playback), store
/// links, and a manual-add form.
final class WantlistViewController: NSViewController {

    private let viewModel = WantlistViewModel()
    private var cancellables = Set<AnyCancellable>()

    private let backdrop = AmbientBackdropView()
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let contentStack = NSStackView()
    private let chipRow = NSStackView()
    private let sectionsStack = NSStackView()
    private let spinner = NSProgressIndicator()
    private let emptyState = NSStackView()

    private var selectedFilter: WantlistFilter = .all
    private var chipButtons: [NSButton] = []
    private let previewController = WantlistPreviewController()

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)

        buildHeader()
        buildEmptyState()

        sectionsStack.orientation = .vertical
        sectionsStack.alignment = .leading
        sectionsStack.spacing = 22

        contentStack.addArrangedSubview(sectionsStack)
        sectionsStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        contentStack.addArrangedSubview(emptyState)
        emptyState.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            contentStack.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 920),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor, constant: 28),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -32),
        ])
        let preferredWidth = contentStack.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -56)
        preferredWidth.priority = NSLayoutConstraint.Priority(490)
        preferredWidth.isActive = true

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        backdrop.apply(ArtworkPaletteExtractor.fallbackPalette(seed: "wantlist"), animated: false)

        viewModel.dataPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.render(data)
            }
            .store(in: &cancellables)
        viewModel.loadingPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                if loading {
                    self?.spinner.startAnimation(nil)
                } else {
                    self?.spinner.stopAnimation(nil)
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged), name: WantlistService.didChange, object: nil
        )

        viewModel.loadCached()
        viewModel.refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        WantlistService.shared.markAllSeen()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        previewController.stop()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        AppLogger.info("WantlistViewController deinit", category: .ui)
    }

    @objc private func storeChanged() {
        viewModel.loadCached()
    }

    private func buildHeader() {
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 16

        let title = NSTextField(labelWithString: "Wantlist")
        title.font = .systemFont(ofSize: 28, weight: .heavy)
        title.textColor = MacColors.primaryLabel

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let addButton = NSButton(title: "Add Manually…", target: self, action: #selector(addManually))
        addButton.bezelStyle = .rounded
        let refreshButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh") ?? NSImage(),
            target: self, action: #selector(refreshTapped)
        )
        refreshButton.bezelStyle = .rounded

        let header = NSStackView(views: [title, spinner, NSView(), addButton, refreshButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        contentStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        chipRow.orientation = .horizontal
        chipRow.spacing = 8
        for filter in WantlistFilter.allCases {
            let chip = NSButton(title: filter.title, target: self, action: #selector(filterChanged(_:)))
            chip.bezelStyle = .toolbar
            chip.setButtonType(.pushOnPushOff)
            chip.tag = filter.rawValue
            chip.state = filter == selectedFilter ? .on : .off
            chipRow.addArrangedSubview(chip)
            chipButtons.append(chip)
        }
        contentStack.addArrangedSubview(chipRow)
    }

    private func buildEmptyState() {
        let icon = NSImageView(image: NSImage(
            systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: nil
        ) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = MacColors.tertiaryLabel
        let title = NSTextField(labelWithString: "Nothing on the wantlist yet")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = MacColors.primaryLabel
        let subtitle = NSTextField(
            labelWithString: "Connect Last.fm in Settings for suggestions from your history, or add wanted albums manually."
        )
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = MacColors.secondaryLabel
        subtitle.alignment = .center
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        emptyState.edgeInsets = NSEdgeInsets(top: 90, left: 0, bottom: 90, right: 0)
        emptyState.addArrangedSubview(icon)
        emptyState.addArrangedSubview(title)
        emptyState.addArrangedSubview(subtitle)
        emptyState.isHidden = true
    }

    private func render(_ data: WantlistData?) {
        sectionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let data else { return }
        let sections = data.filtered(by: selectedFilter)
        emptyState.isHidden = !sections.isEmpty
        for (section, items) in sections {
            let header = NSTextField(labelWithString: section.headerTitle)
            header.font = .systemFont(ofSize: 17, weight: .bold)
            header.textColor = MacColors.primaryLabel
            sectionsStack.addArrangedSubview(header)

            if usesGrid(section) {
                let grid = gridView(items: items)
                sectionsStack.addArrangedSubview(grid)
                grid.widthAnchor.constraint(equalTo: sectionsStack.widthAnchor).isActive = true
            } else {
                let list = NSStackView()
                list.orientation = .vertical
                list.alignment = .leading
                list.spacing = 4
                for item in items {
                    let row = makeRow(item: item)
                    list.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                }
                let card = RecapCard.host(padded(list))
                sectionsStack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: sectionsStack.widthAnchor).isActive = true
            }
        }
    }

    private func usesGrid(_ section: WantlistSection) -> Bool {
        switch section {
        case .newReleases, .albums, .discoverAlbums: true
        default: false
        }
    }

    private func padded(_ view: NSStackView) -> NSStackView {
        view.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        return view
    }

    private func gridView(items: [WantlistItem]) -> NSView {
        let columns = 6
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 14
        var rowStack: NSStackView?
        for (offset, item) in items.enumerated() {
            if offset % columns == 0 {
                let row = NSStackView()
                row.orientation = .horizontal
                row.alignment = .top
                row.spacing = 14
                row.distribution = .fillEqually
                grid.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
                rowStack = row
            }
            rowStack?.addArrangedSubview(makeAlbumCard(item: item))
        }
        if let last = grid.arrangedSubviews.last as? NSStackView {
            let missing = (columns - items.count % columns) % columns
            for _ in 0..<missing {
                last.addArrangedSubview(NSView())
            }
        }
        return grid
    }

    private func makeAlbumCard(item: WantlistItem) -> NSView {
        guard case .album(let album, let meta) = item else { return NSView() }
        let artwork = RemoteArtworkView()
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.heightAnchor.constraint(equalTo: artwork.widthAnchor).isActive = true
        artwork.configure(
            localAlbum: nil, localArtist: nil, remoteURL: album.imageURL,
            placeholderSeed: "\(album.name)|\(album.artist)"
        )

        let name = NSTextField(labelWithString: album.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = MacColors.primaryLabel
        name.lineBreakMode = .byTruncatingTail
        let artist = NSTextField(labelWithString: album.artist)
        artist.font = .systemFont(ofSize: 10)
        artist.textColor = MacColors.secondaryLabel
        artist.lineBreakMode = .byTruncatingTail
        let reason = NSTextField(labelWithString: meta.reason)
        reason.font = .systemFont(ofSize: 9)
        reason.textColor = MacColors.tertiaryLabel
        reason.lineBreakMode = .byTruncatingTail

        let stack = ClickableStackView(views: [artwork, name, artist, reason])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        artwork.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.toolTip = "\(album.name) — \(album.artist)\n\(meta.reason)"
        stack.menu = itemMenu(title: album.name, artist: album.artist, meta: meta, isTrack: false)
        stack.clickAction = { [weak self, weak stack] in
            guard let stack else { return }
            stack.menu?.popUp(positioning: nil, at: NSPoint(x: 8, y: 8), in: stack)
            _ = self
        }
        return stack
    }

    private func makeRow(item: WantlistItem) -> NSView {
        let title: String
        let subtitle: String
        let meta: WantlistRowMeta
        let seed: String
        var isTrack = false
        switch item {
        case .album(let album, let rowMeta):
            title = album.name
            subtitle = "\(album.artist) · \(rowMeta.reason)"
            meta = rowMeta
            seed = "\(album.name)|\(album.artist)"
        case .track(let track, let rowMeta):
            title = track.name
            subtitle = "\(track.artist) · \(rowMeta.reason)"
            meta = rowMeta
            seed = "\(track.name)|\(track.artist)"
            isTrack = true
        case .artist(let artist, let rowMeta):
            title = artist.name
            subtitle = rowMeta.reason
            meta = rowMeta
            seed = artist.name
        }
        let (itemArtist, itemTitle) = itemIdentity(item)

        let artwork = RemoteArtworkView()
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.widthAnchor.constraint(equalToConstant: 42).isActive = true
        artwork.heightAnchor.constraint(equalToConstant: 42).isActive = true
        if case .album(let album, _) = item {
            artwork.configure(localAlbum: nil, localArtist: nil, remoteURL: album.imageURL, placeholderSeed: seed)
        } else {
            artwork.configure(localAlbum: nil, localArtist: nil, remoteURL: nil, placeholderSeed: seed)
        }

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = MacColors.primaryLabel
        titleLabel.lineBreakMode = .byTruncatingTail
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = MacColors.secondaryLabel
        subtitleLabel.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        var trailing: [NSView] = []
        if isTrack {
            let previewButton = HoverActionButton(symbolName: "play.circle", tooltip: "Preview 30 seconds")
            previewButton.onTap = { [weak self, weak previewButton] in
                guard let self else { return }
                self.previewController.togglePreview(title: itemTitle, artist: itemArtist, button: previewButton)
            }
            trailing.append(previewButton)
        }
        let openButton = HoverActionButton(symbolName: "arrow.up.right.square", tooltip: "Open in Apple Music")
        openButton.onTap = { [weak self] in
            self?.openInStore(title: itemTitle, artist: itemArtist, storeURL: meta.storeURL)
        }
        trailing.append(openButton)
        let gotItButton = HoverActionButton(symbolName: "checkmark.circle", tooltip: "Got It")
        gotItButton.onTap = { [weak self] in
            self?.setState(.acquired, normKey: meta.normKey, name: itemTitle)
        }
        trailing.append(gotItButton)
        let dismissButton = HoverActionButton(symbolName: "xmark.circle", tooltip: "Dismiss")
        dismissButton.onTap = { [weak self] in
            self?.setState(.dismissed, normKey: meta.normKey, name: itemTitle)
        }
        trailing.append(dismissButton)

        let row = NSStackView(views: [artwork, text, NSView()] + trailing)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        row.menu = itemMenu(title: itemTitle, artist: itemArtist, meta: meta, isTrack: isTrack)
        return row
    }

    private func itemIdentity(_ item: WantlistItem) -> (artist: String, title: String) {
        switch item {
        case .album(let album, _): (album.artist, album.name)
        case .track(let track, _): (track.artist, track.name)
        case .artist(let artist, _): (artist.name, artist.name)
        }
    }

    private func itemMenu(title: String, artist: String, meta: WantlistRowMeta, isTrack: Bool) -> NSMenu {
        let menu = NSMenu()
        let context = WantlistMenuContext(title: title, artist: artist, meta: meta)
        if isTrack {
            let preview = menu.addItem(withTitle: "Preview 30 Seconds", action: #selector(menuPreview(_:)), keyEquivalent: "")
            preview.target = self
            preview.representedObject = context
        }
        let open = menu.addItem(withTitle: "Open in Apple Music", action: #selector(menuOpen(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = context
        menu.addItem(.separator())
        let gotIt = menu.addItem(withTitle: "Got It", action: #selector(menuGotIt(_:)), keyEquivalent: "")
        gotIt.target = self
        gotIt.representedObject = context
        let dismiss = menu.addItem(withTitle: "Dismiss", action: #selector(menuDismiss(_:)), keyEquivalent: "")
        dismiss.target = self
        dismiss.representedObject = context
        return menu
    }

    @objc private func menuPreview(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? WantlistMenuContext else { return }
        previewController.togglePreview(title: context.title, artist: context.artist, button: nil)
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? WantlistMenuContext else { return }
        openInStore(title: context.title, artist: context.artist, storeURL: context.meta.storeURL)
    }

    @objc private func menuGotIt(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? WantlistMenuContext else { return }
        setState(.acquired, normKey: context.meta.normKey, name: context.title)
    }

    @objc private func menuDismiss(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? WantlistMenuContext else { return }
        setState(.dismissed, normKey: context.meta.normKey, name: context.title)
    }

    private func setState(_ state: WantlistState, normKey: String, name: String) {
        WantlistService.shared.setState(state, normKey: normKey)
        let verb = state == .acquired ? "Marked as acquired" : "Dismissed"
        MacToast.show("\(verb): \(name)", style: .success, in: view.window)
    }

    private func openInStore(title: String, artist: String, storeURL: String?) {
        if let storeURL, let url = URL(string: storeURL) {
            NSWorkspace.shared.open(url)
            return
        }
        let term = "\(artist) \(title)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://music.apple.com/us/search?term=\(term)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func filterChanged(_ sender: NSButton) {
        guard let filter = WantlistFilter(rawValue: sender.tag) else { return }
        selectedFilter = filter
        for chip in chipButtons {
            chip.state = chip.tag == filter.rawValue ? .on : .off
        }
        render(viewModel.dataPublisher.value)
    }

    @objc private func refreshTapped() {
        viewModel.refresh()
    }

    @objc private func addManually() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Add to Wantlist"
        alert.informativeText = "Track a wanted album, song, or artist."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let form = NSStackView(frame: NSRect(x: 0, y: 0, width: 260, height: 96))
        form.orientation = .vertical
        form.spacing = 8
        form.alignment = .leading
        let kindPopUp = NSPopUpButton()
        kindPopUp.addItems(withTitles: ["Album", "Song", "Artist"])
        let titleField = NSTextField(frame: .zero)
        titleField.placeholderString = "Title"
        let artistField = NSTextField(frame: .zero)
        artistField.placeholderString = "Artist"
        form.addArrangedSubview(kindPopUp)
        form.addArrangedSubview(titleField)
        form.addArrangedSubview(artistField)
        titleField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        artistField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        alert.accessoryView = form

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let artist = artistField.stringValue.trimmingCharacters(in: .whitespaces)
            var title = titleField.stringValue.trimmingCharacters(in: .whitespaces)
            let kind: WantlistKind = switch kindPopUp.indexOfSelectedItem {
            case 1: .track
            case 2: .artist
            default: .album
            }
            if kind == .artist {
                title = ""
            }
            guard !artist.isEmpty, kind == .artist || !title.isEmpty else { return }
            WantlistService.shared.addManual(
                kind: kind, title: title, artist: artist, imageURL: nil
            )
            self?.viewModel.loadCached()
        }
    }
}

private final class WantlistMenuContext: NSObject {
    let title: String
    let artist: String
    let meta: WantlistRowMeta

    init(title: String, artist: String, meta: WantlistRowMeta) {
        self.title = title
        self.artist = artist
        self.meta = meta
    }
}

/// Small circular icon button that brightens on hover, used for row actions.
final class HoverActionButton: NSControl {

    var onTap: (() -> Void)?

    private let icon = NSImageView()
    private var isHovered = false

    init(symbolName: String, tooltip: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = MacColors.secondaryLabel
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        toolTip = tooltip
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 24),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(tooltip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacColors.fill(0.14).cgColor
        }
        icon.contentTintColor = MacColors.primaryLabel
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = NSColor.clear.cgColor
        icon.contentTintColor = MacColors.secondaryLabel
    }

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func setSymbol(_ symbolName: String) {
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
    }
}

/// Plays 30-second iTunes previews with desktop-appropriate etiquette: pauses
/// the main player when a preview starts and resumes it when the preview
/// stops or finishes.
final class WantlistPreviewController {

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var currentKey: String?
    private var resumeMainPlayback = false
    private weak var activeButton: HoverActionButton?

    func togglePreview(title: String, artist: String, button: HoverActionButton?) {
        let key = "\(title)\u{0}\(artist)"
        if currentKey == key {
            stop()
            return
        }
        stop()
        currentKey = key
        activeButton = button
        button?.setSymbol("hourglass")
        Task { [weak self] in
            guard let url = await WantlistService.fetchPreviewURL(title: title, artist: artist) else {
                await MainActor.run { [weak self] in
                    guard let self, self.currentKey == key else { return }
                    self.activeButton?.setSymbol("play.circle")
                    self.currentKey = nil
                    MacToast.show("No preview available", style: .info, in: nil)
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self, self.currentKey == key else { return }
                self.startPlaying(url: url, key: key)
            }
        }
    }

    func stop() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
        activeButton?.setSymbol("play.circle")
        activeButton = nil
        currentKey = nil
        if resumeMainPlayback {
            resumeMainPlayback = false
            if !AudioPlayer.shared.isPlaying {
                AudioPlayer.shared.togglePlayPause()
            }
        }
    }

    private func startPlaying(url: URL, key: String) {
        if AudioPlayer.shared.isPlaying {
            resumeMainPlayback = true
            AudioPlayer.shared.togglePlayPause()
        }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }
        self.player = player
        activeButton?.setSymbol("stop.circle")
        player.play()
        AppLogger.info("Wantlist preview started: \(key)", category: .playback)
    }
}
