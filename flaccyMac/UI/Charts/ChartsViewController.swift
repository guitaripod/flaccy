import AppKit
import UniformTypeIdentifiers
import Combine

/// The Recap dashboard: period picker, headline stat tiles, ranked top lists,
/// the listening clock and full-width heatmap with hover tooltips, the
/// Last.fm import-history banner with live progress, and share-card export.
/// Forced dark over an ambient palette backdrop, all stats computed off-main
/// by ChartsViewModel.
final class ChartsViewController: NSViewController {

    private let viewModel = ChartsViewModel()
    private var cancellables = Set<AnyCancellable>()

    private let backdrop = AmbientBackdropView()
    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private let documentView = FlippedView()

    private let periodPicker = NSSegmentedControl()
    private let profileLabel = NSTextField(labelWithString: "")
    private let shareButton = NSButton(title: "Share", target: nil, action: nil)

    private let importBanner = NSView()
    private let importLabel = NSTextField(labelWithString: "")
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let importSpinner = NSProgressIndicator()

    private let statsRow = NSStackView()
    private let artistsList = NSStackView()
    private let albumsGrid = NSStackView()
    private let tracksList = NSStackView()
    private let clockView = MacListeningClockView()
    private let heatmapView = MacHeatmapView()
    private let streakLabel = NSTextField(labelWithString: "")
    private let personaTitleLabel = NSTextField(labelWithString: "")
    private let personaBlurbLabel = NSTextField(labelWithString: "")
    private let personaIcon = NSImageView()

    private let skeletonContainer = NSStackView()
    private let emptyState = NSStackView()

    private var sectionViews: [NSView] = []
    private var accent: NSColor = .systemIndigo

    override func loadView() {
        let root = AppearanceObservingView()
        root.wantsLayer = true
        root.onEffectiveAppearanceChange = { [weak self] in self?.applyDynamicLayerColors() }

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(backdrop)

        buildContent()
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
        applyDynamicLayerColors()
    }

    private func applyDynamicLayerColors() {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            importBanner.layer?.backgroundColor = MacColors.fill(0.08).cgColor
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        backdrop.apply(ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy-recap"), animated: false)
        accent = ArtworkPaletteExtractor.fallbackPalette(seed: "flaccy-recap").dominant

        viewModel.dataPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                self?.render(data)
            }
            .store(in: &cancellables)
        viewModel.loadingPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                self?.setLoading(loading)
            }
            .store(in: &cancellables)
        viewModel.importStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.renderImportState(state)
            }
            .store(in: &cancellables)

        setLoading(true)
        viewModel.load(period: viewModel.selectedPeriod)
    }

    deinit {
        AppLogger.info("ChartsViewController deinit", category: .ui)
    }

    private func buildContent() {
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18

        let title = NSTextField(labelWithString: "Recap")
        title.font = .systemFont(ofSize: 28, weight: .heavy)
        title.textColor = MacColors.primaryLabel

        profileLabel.font = .systemFont(ofSize: 12)
        profileLabel.textColor = MacColors.secondaryLabel

        shareButton.bezelStyle = .rounded
        shareButton.controlSize = .regular
        shareButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share recap")
        shareButton.imagePosition = .imageLeading
        shareButton.target = self
        shareButton.action = #selector(shareTapped)

        let titleColumn = NSStackView(views: [title, profileLabel])
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 2

        periodPicker.segmentCount = ChartPeriod.allCases.count
        for (index, period) in ChartPeriod.allCases.enumerated() {
            periodPicker.setLabel(period.shortName, forSegment: index)
            periodPicker.setWidth(0, forSegment: index)
        }
        periodPicker.selectedSegment = ChartPeriod.allCases.firstIndex(of: viewModel.selectedPeriod) ?? 0
        periodPicker.target = self
        periodPicker.action = #selector(periodChanged)
        periodPicker.segmentStyle = .capsule

        let header = NSStackView(views: [titleColumn, NSView(), periodPicker, shareButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        contentStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        buildImportBanner()
        buildStatsRow()
        buildSkeleton()
        buildEmptyState()

        sectionViews = [
            statsRow,
            sectionCard(title: "Top Artists", content: hostedList(artistsList)),
            sectionCard(title: "Top Albums", content: hostedList(albumsGrid)),
            sectionCard(title: "Top Tracks", content: hostedList(tracksList)),
            sectionCard(title: "Listening Clock", content: clockCardContent()),
            sectionCard(title: "Your Streak", content: heatmapCardContent()),
            sectionCard(title: "Your Persona", content: personaCardContent()),
        ]
        for section in sectionViews {
            contentStack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        contentStack.addArrangedSubview(skeletonContainer)
        skeletonContainer.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        contentStack.addArrangedSubview(emptyState)
        emptyState.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
    }

    private func buildImportBanner() {
        importBanner.wantsLayer = true
        importBanner.layer?.backgroundColor = MacColors.fill(0.08).cgColor
        importBanner.layer?.cornerRadius = 14
        importBanner.layer?.cornerCurve = .continuous

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "square.and.arrow.down.on.square", accessibilityDescription: nil
        ) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 16, weight: .medium)
        icon.contentTintColor = MacColors.primaryLabel

        importLabel.font = .systemFont(ofSize: 12, weight: .medium)
        importLabel.textColor = MacColors.primaryLabel
        importLabel.maximumNumberOfLines = 2
        importLabel.lineBreakMode = .byWordWrapping

        importButton.bezelStyle = .rounded
        importButton.controlSize = .small
        importButton.target = self
        importButton.action = #selector(importTapped)

        importSpinner.style = .spinning
        importSpinner.controlSize = .small
        importSpinner.isDisplayedWhenStopped = false

        let row = NSStackView(views: [icon, importLabel, NSView(), importSpinner, importButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        importBanner.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: importBanner.topAnchor),
            row.leadingAnchor.constraint(equalTo: importBanner.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: importBanner.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: importBanner.bottomAnchor),
        ])
        contentStack.addArrangedSubview(importBanner)
        importBanner.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        importBanner.isHidden = true
    }

    private func buildStatsRow() {
        statsRow.orientation = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.spacing = 12
    }

    private func buildSkeleton() {
        skeletonContainer.orientation = .vertical
        skeletonContainer.spacing = 14
        skeletonContainer.alignment = .leading
        let tiles = NSStackView(views: (0..<4).map { _ in ShimmerBlock(cornerRadius: 16) })
        tiles.orientation = .horizontal
        tiles.distribution = .fillEqually
        tiles.spacing = 12
        tiles.heightAnchor.constraint(equalToConstant: 88).isActive = true
        skeletonContainer.addArrangedSubview(tiles)
        tiles.widthAnchor.constraint(equalTo: skeletonContainer.widthAnchor).isActive = true
        for _ in 0..<3 {
            let block = ShimmerBlock(cornerRadius: 16)
            block.heightAnchor.constraint(equalToConstant: 180).isActive = true
            skeletonContainer.addArrangedSubview(block)
            block.widthAnchor.constraint(equalTo: skeletonContainer.widthAnchor).isActive = true
        }
    }

    private func buildEmptyState() {
        let icon = NSImageView(image: NSImage(
            systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil
        ) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = MacColors.tertiaryLabel
        let title = NSTextField(labelWithString: "No listening history yet")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = MacColors.primaryLabel
        let subtitle = NSTextField(labelWithString: "Play some music, or connect Last.fm in Settings and import your history.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = MacColors.secondaryLabel
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        emptyState.edgeInsets = NSEdgeInsets(top: 100, left: 0, bottom: 100, right: 0)
        emptyState.addArrangedSubview(icon)
        emptyState.addArrangedSubview(title)
        emptyState.addArrangedSubview(subtitle)
        emptyState.isHidden = true
    }

    private func sectionCard(title: String, content: NSView) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 17, weight: .bold)
        header.textColor = MacColors.primaryLabel
        content.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [header, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func hostedList(_ list: NSStackView) -> NSView {
        list.orientation = list === albumsGrid ? .horizontal : .vertical
        list.alignment = list === albumsGrid ? .top : .leading
        list.spacing = list === albumsGrid ? 14 : 4
        if list === albumsGrid {
            list.distribution = .fillEqually
        }
        list.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        return RecapCard.host(list)
    }

    private func clockCardContent() -> NSView {
        clockView.translatesAutoresizingMaskIntoConstraints = false
        clockView.heightAnchor.constraint(equalToConstant: 230).isActive = true
        let stack = NSStackView(views: [clockView])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        clockView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        return RecapCard.host(stack)
    }

    private func heatmapCardContent() -> NSView {
        streakLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        streakLabel.textColor = MacColors.primaryLabel
        heatmapView.translatesAutoresizingMaskIntoConstraints = false
        heatmapView.heightAnchor.constraint(equalToConstant: 130).isActive = true
        let stack = NSStackView(views: [streakLabel, heatmapView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        heatmapView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        return RecapCard.host(stack)
    }

    private func personaCardContent() -> NSView {
        personaIcon.symbolConfiguration = .init(pointSize: 22, weight: .semibold)
        personaTitleLabel.font = .systemFont(ofSize: 19, weight: .bold)
        personaTitleLabel.textColor = MacColors.primaryLabel
        personaBlurbLabel.font = .systemFont(ofSize: 12)
        personaBlurbLabel.textColor = MacColors.secondaryLabel
        let text = NSStackView(views: [personaTitleLabel, personaBlurbLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [personaIcon, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        return RecapCard.host(row)
    }

    private func setLoading(_ loading: Bool) {
        let hasData = viewModel.data != nil
        skeletonContainer.isHidden = !loading || hasData
        if loading, !hasData {
            sectionViews.forEach { $0.isHidden = true }
            emptyState.isHidden = true
        }
    }

    private func render(_ data: RecapData?) {
        guard let data else { return }
        skeletonContainer.isHidden = true

        let isEmpty = !data.hasContent
        emptyState.isHidden = !isEmpty
        sectionViews.forEach { $0.isHidden = isEmpty }
        guard !isEmpty else { return }

        if let info = data.userInfo {
            var pieces = [info.name]
            if info.registeredUts > 0 {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy"
                pieces.append("scrobbling since \(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(info.registeredUts))))")
            }
            profileLabel.stringValue = pieces.joined(separator: " · ")
        } else {
            profileLabel.stringValue = "Local listening history"
        }

        renderStats(data)
        renderArtists(data)
        renderAlbums(data)
        renderTracks(data)

        clockView.configure(buckets: data.listeningClock, tint: accent)
        heatmapView.configure(counts: data.heatmap, tint: accent)
        streakLabel.stringValue = data.streak > 0
            ? "\(data.streak) day\(data.streak == 1 ? "" : "s") in a row and counting"
            : "No active streak — press play to start one"

        personaTitleLabel.stringValue = data.persona
        personaBlurbLabel.stringValue = RecapPersona.blurb(for: data.persona)
        personaIcon.image = NSImage(systemSymbolName: RecapPersona.symbol(for: data.persona), accessibilityDescription: nil)
        personaIcon.contentTintColor = accent
    }

    private func renderStats(_ data: RecapData) {
        statsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let tiles: [(String, String, String)] = [
            (RecapFormat.count(data.totalPlays), "PLAYS", "play.circle.fill"),
            (RecapFormat.count(data.totalMinutes), "MINUTES", "clock.fill"),
            ("\(data.streak)", "DAY STREAK", "flame.fill"),
            (data.persona, "PERSONA", RecapPersona.symbol(for: data.persona)),
        ]
        for (value, caption, symbol) in tiles {
            statsRow.addArrangedSubview(statTile(value: value, caption: caption, symbol: symbol))
        }
    }

    private func statTile(value: String, caption: String, symbol: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        icon.contentTintColor = accent
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .systemFont(ofSize: 24, weight: .heavy)
        valueLabel.textColor = MacColors.primaryLabel
        valueLabel.lineBreakMode = .byTruncatingTail
        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.font = .systemFont(ofSize: 10, weight: .bold)
        captionLabel.textColor = MacColors.secondaryLabel
        let stack = NSStackView(views: [icon, valueLabel, captionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        return RecapCard.host(stack, cornerRadius: 16)
    }

    private func renderArtists(_ data: RecapData) {
        artistsList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let index = RecapLibraryIndex(albums: Library.shared.albums, tracks: Library.shared.allTracks)
        for artist in data.topArtists.prefix(10) {
            let album = index.representativeAlbum(forArtist: artist.name)
            let row = rankedRow(
                rank: artist.rank, title: artist.name, subtitle: nil, plays: artist.playCount,
                localAlbum: album?.title, localArtist: album?.artist, remoteURL: nil,
                seed: artist.name, circular: true
            )
            row.clickAction = { [weak self] in
                self?.reveal(artist: artist.name)
            }
            artistsList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: artistsList.widthAnchor, constant: -28).isActive = true
        }
    }

    private func renderTracks(_ data: RecapData) {
        tracksList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let index = RecapLibraryIndex(albums: Library.shared.albums, tracks: Library.shared.allTracks)
        for track in data.topTracks.prefix(10) {
            let local = index.track(title: track.name, artist: track.artistName)
            let row = rankedRow(
                rank: track.rank, title: track.name, subtitle: track.artistName, plays: track.playCount,
                localAlbum: local?.albumTitle, localArtist: local?.artist, remoteURL: nil,
                seed: "\(track.name)|\(track.artistName)", circular: false
            )
            if let local {
                row.clickAction = { [weak self] in
                    self?.reveal(albumTitle: local.albumTitle, artist: local.artist)
                }
            }
            tracksList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: tracksList.widthAnchor, constant: -28).isActive = true
        }
    }

    private func renderAlbums(_ data: RecapData) {
        albumsGrid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let index = RecapLibraryIndex(albums: Library.shared.albums, tracks: Library.shared.allTracks)
        for album in data.topAlbums.prefix(6) {
            let local = index.album(name: album.name, artist: album.artistName)
            let tile = albumTile(album: album, local: local)
            albumsGrid.addArrangedSubview(tile)
        }
    }

    private func albumTile(album: ChartAlbum, local: Album?) -> NSView {
        let artwork = RemoteArtworkView()
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.configure(
            localAlbum: local?.title ?? album.name,
            localArtist: local?.artist ?? album.artistName,
            remoteURL: album.imageURL,
            placeholderSeed: "\(album.name)|\(album.artistName)"
        )
        artwork.heightAnchor.constraint(equalTo: artwork.widthAnchor).isActive = true

        let name = NSTextField(labelWithString: album.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = MacColors.primaryLabel
        name.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: "\(album.artistName) · \(RecapFormat.compact(album.playCount)) plays")
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = MacColors.secondaryLabel
        detail.lineBreakMode = .byTruncatingTail

        let stack = ClickableStackView(views: [artwork, name, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        artwork.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.clickAction = { [weak self] in
            self?.reveal(albumTitle: local?.title ?? album.name, artist: local?.artist ?? album.artistName)
        }
        stack.toolTip = "\(album.name) — \(album.artistName)"
        return stack
    }

    private func rankedRow(
        rank: Int, title: String, subtitle: String?, plays: Int,
        localAlbum: String?, localArtist: String?, remoteURL: String?,
        seed: String, circular: Bool
    ) -> ClickableStackView {
        let rankLabel = NSTextField(labelWithString: "\(rank)")
        rankLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .heavy)
        rankLabel.textColor = accent
        rankLabel.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let artwork = RemoteArtworkView()
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.widthAnchor.constraint(equalToConstant: 36).isActive = true
        artwork.heightAnchor.constraint(equalToConstant: 36).isActive = true
        artwork.cornerRadius = circular ? 18 : 6
        artwork.configure(
            localAlbum: localAlbum, localArtist: localArtist, remoteURL: remoteURL, placeholderSeed: seed
        )

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = MacColors.primaryLabel
        titleLabel.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [titleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        if let subtitle {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11)
            subtitleLabel.textColor = MacColors.secondaryLabel
            subtitleLabel.lineBreakMode = .byTruncatingTail
            text.addArrangedSubview(subtitleLabel)
        }

        let playsLabel = NSTextField(labelWithString: "\(RecapFormat.compact(plays)) plays")
        playsLabel.font = .systemFont(ofSize: 11, weight: .medium)
        playsLabel.textColor = MacColors.secondaryLabel
        playsLabel.setContentHuggingPriority(.required, for: .horizontal)
        playsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = ClickableStackView(views: [rankLabel, artwork, text, NSView(), playsLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
        return row
    }

    private func reveal(artist: String) {
        LibraryNavigator.revealArtist(artist)
    }

    private func reveal(albumTitle: String, artist: String) {
        LibraryNavigator.revealAlbum(title: albumTitle, artist: artist)
    }

    private func renderImportState(_ state: RecapImportState) {
        importBanner.isHidden = !state.showsBanner
        switch state {
        case .available:
            importLabel.stringValue = "Import your full Last.fm history to power the Recap and Year in Music."
            importButton.isHidden = false
            importButton.isEnabled = true
            importSpinner.stopAnimation(nil)
        case .importing(let imported):
            importLabel.stringValue = imported > 0
                ? "Importing history… \(RecapFormat.count(imported)) scrobbles so far"
                : "Importing history…"
            importButton.isHidden = true
            importSpinner.startAnimation(nil)
        case .done(let imported):
            importLabel.stringValue = "Imported \(RecapFormat.count(imported)) scrobbles from Last.fm."
            importButton.isHidden = true
            importSpinner.stopAnimation(nil)
        case .unavailable:
            break
        }
    }

    @objc private func periodChanged() {
        let index = periodPicker.selectedSegment
        guard index >= 0, index < ChartPeriod.allCases.count else { return }
        viewModel.load(period: ChartPeriod.allCases[index])
    }

    @objc private func importTapped() {
        viewModel.importHistory()
    }

    @objc private func shareTapped() {
        guard let data = viewModel.data else { return }
        let palette = ArtworkPaletteExtractor.fallbackPalette(seed: data.persona + data.period.rawValue)
        guard let image = RecapShareCardRenderer.makeImage(data: data, palette: palette) else {
            MacToast.show("Couldn't render the share card.", style: .error, in: view.window)
            return
        }
        let menu = NSMenu()
        let share = menu.addItem(withTitle: "Share…", action: #selector(shareImage(_:)), keyEquivalent: "")
        share.target = self
        share.representedObject = image
        let save = menu.addItem(withTitle: "Save PNG…", action: #selector(saveImage(_:)), keyEquivalent: "")
        save.target = self
        save.representedObject = image
        let copy = menu.addItem(withTitle: "Copy Image", action: #selector(copyImage(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = image
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: shareButton.bounds.height + 4), in: shareButton)
    }

    @objc private func shareImage(_ sender: NSMenuItem) {
        guard let image = sender.representedObject as? NSImage else { return }
        let picker = NSSharingServicePicker(items: [image])
        picker.show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY)
    }

    @objc private func saveImage(_ sender: NSMenuItem) {
        guard let image = sender.representedObject as? NSImage, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Flaccy Recap.png"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            guard let data = image.pngData() else { return }
            do {
                try data.write(to: url)
                AppLogger.info("Recap share card saved to \(url.path)", category: .ui)
            } catch {
                AppLogger.error("Recap card save failed: \(error.localizedDescription)", category: .ui)
            }
        }
    }

    @objc private func copyImage(_ sender: NSMenuItem) {
        guard let image = sender.representedObject as? NSImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        MacToast.show("Recap card copied", style: .success, in: view.window)
    }
}

/// Root view that forwards effective-appearance changes so layer-backed colors
/// can be recomputed for the active appearance.
final class AppearanceObservingView: NSView {

    var onEffectiveAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }
}

/// Stack view that runs a closure on click and shows a pointing-hand cursor.
final class ClickableStackView: NSStackView {

    var clickAction: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if clickAction != nil {
            clickAction?()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resetCursorRects() {
        if clickAction != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}
