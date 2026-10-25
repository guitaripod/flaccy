import AppKit
import MidgarCore
import UniformTypeIdentifiers
import Combine

/// The Recap dashboard: period picker, headline stat tiles, ranked top lists,
/// the listening clock and full-width heatmap with hover tooltips, the
/// Last.fm history-sync banner with live progress, and share-card export.
/// Forced dark over an ambient palette backdrop, all stats computed off-main
/// by ChartsViewModel.
final class ChartsViewController: NSViewController {

    private let viewModel = ChartsViewModel(initialPeriod: .week)
    private var cancellables = Set<AnyCancellable>()

    private let backdrop = AmbientBackdropView()
    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private let documentView = FlippedView()

    private let periodPicker = NSSegmentedControl()
    private let profileLabel = NSTextField(labelWithString: "")
    private let shareButton = NSButton(title: String(localized: "Share"), target: nil, action: nil)
    private let loadingSpinner = NSProgressIndicator()

    private let syncBanner = NSView()
    private let syncLabel = NSTextField(labelWithString: "")
    private let syncSpinner = NSProgressIndicator()

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

    private enum ChartList: CaseIterable {
        case artists, albums, tracks
    }

    private var playQueues: [ChartList: [Track]] = [:]
    private var listActions: [ChartList: NSView] = [:]

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
            syncBanner.layer?.backgroundColor = MacColors.fill(0.08).cgColor
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
        viewModel.syncStatusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.renderSyncStatus(status)
            }
            .store(in: &cancellables)

        setLoading(true)
        viewModel.load(period: viewModel.selectedPeriod)
    }

    deinit {
        MidgarLog.info("ChartsViewController deinit", category: .ui)
    }

    private func buildContent() {
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 18

        let title = NSTextField(labelWithString: String(localized: "Recap"))
        title.font = .systemFont(ofSize: 28, weight: .heavy)
        title.textColor = MacColors.primaryLabel

        profileLabel.font = .systemFont(ofSize: 12)
        profileLabel.textColor = MacColors.secondaryLabel

        shareButton.bezelStyle = .rounded
        shareButton.controlSize = .regular
        shareButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: String(localized: "Share recap"))
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

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .small
        loadingSpinner.isDisplayedWhenStopped = false

        let header = NSStackView(views: [titleColumn, NSView(), loadingSpinner, periodPicker, shareButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        contentStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        buildSyncBanner()
        buildStatsRow()
        buildSkeleton()
        buildEmptyState()

        sectionViews = [
            statsRow,
            sectionCard(title: String(localized: "Top Artists"), content: hostedList(artistsList), actions: listActionsView(for: .artists)),
            sectionCard(title: String(localized: "Top Albums"), content: hostedList(albumsGrid), actions: listActionsView(for: .albums)),
            sectionCard(title: String(localized: "Top Tracks"), content: hostedList(tracksList), actions: listActionsView(for: .tracks)),
            sectionCard(title: String(localized: "Listening Clock"), content: clockCardContent()),
            sectionCard(title: String(localized: "Your Streak"), content: heatmapCardContent()),
            sectionCard(title: String(localized: "Your Persona"), content: personaCardContent()),
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

    private func buildSyncBanner() {
        syncBanner.wantsLayer = true
        syncBanner.layer?.backgroundColor = MacColors.fill(0.08).cgColor
        syncBanner.layer?.cornerRadius = 14
        syncBanner.layer?.cornerCurve = .continuous

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "square.and.arrow.down.on.square", accessibilityDescription: nil
        ) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 16, weight: .medium)
        icon.contentTintColor = MacColors.primaryLabel

        syncLabel.font = .systemFont(ofSize: 12, weight: .medium)
        syncLabel.textColor = MacColors.primaryLabel
        syncLabel.maximumNumberOfLines = 2
        syncLabel.lineBreakMode = .byWordWrapping

        syncSpinner.style = .spinning
        syncSpinner.controlSize = .small
        syncSpinner.isDisplayedWhenStopped = false

        let row = NSStackView(views: [icon, syncLabel, NSView(), syncSpinner])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        syncBanner.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: syncBanner.topAnchor),
            row.leadingAnchor.constraint(equalTo: syncBanner.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: syncBanner.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: syncBanner.bottomAnchor),
        ])
        contentStack.addArrangedSubview(syncBanner)
        syncBanner.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        syncBanner.isHidden = true
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
        let title = NSTextField(labelWithString: String(localized: "No listening history yet"))
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = MacColors.primaryLabel
        let subtitle = NSTextField(labelWithString: String(localized: "Play some music, or connect Last.fm in Settings to bring in your history."))
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

    private func sectionCard(title: String, content: NSView, actions: NSView? = nil) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 17, weight: .bold)
        heading.textColor = MacColors.primaryLabel
        let header = NSStackView(views: [heading, NSView()] + (actions.map { [$0] } ?? []))
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [header, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func listActionsView(for list: ChartList) -> NSView {
        let play = GlassCapsuleButton(title: String(localized: "Play"), symbolName: "play.fill", prominent: true)
        play.onClick = { [weak self] in self?.play(list, shuffled: false) }
        let shuffle = GlassCapsuleButton(title: String(localized: "Shuffle"), symbolName: "shuffle")
        shuffle.onClick = { [weak self] in self?.play(list, shuffled: true) }
        let actions = MacLiquidGlass.buttonGroup([play, shuffle])
        actions.isHidden = true
        listActions[list] = actions
        return actions
    }

    private func refreshPlayQueues(_ data: RecapData, index: RecapLibraryIndex) {
        playQueues = [
            .artists: index.queue(forArtists: data.topArtists),
            .albums: index.queue(forAlbums: data.topAlbums),
            .tracks: index.queue(forTracks: data.topTracks),
        ]
        for list in ChartList.allCases {
            listActions[list]?.isHidden = playQueues[list]?.isEmpty != false
        }
    }

    private func play(_ list: ChartList, shuffled: Bool) {
        guard let queue = playQueues[list], !queue.isEmpty else { return }
        MidgarLog.info("Recap play list: \(list) (\(queue.count) tracks, shuffled: \(shuffled))", category: .playback)
        AudioPlayer.shared.play(shuffled ? queue.shuffled() : queue, startingAt: 0)
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

    /// First load shows the skeleton; every later load keeps the previous
    /// period on screen and only spins a small indicator beside the picker, so
    /// flipping periods never blanks the page.
    private func setLoading(_ loading: Bool) {
        let hasData = viewModel.data != nil
        skeletonContainer.isHidden = !loading || hasData
        if loading, !hasData {
            sectionViews.forEach { $0.isHidden = true }
            emptyState.isHidden = true
        }
        if loading, hasData {
            loadingSpinner.startAnimation(nil)
        } else {
            loadingSpinner.stopAnimation(nil)
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
                formatter.setLocalizedDateFormatFromTemplate("yyyy")
                pieces.append(String(localized: "scrobbling since \(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(info.registeredUts))))"))
            }
            profileLabel.stringValue = pieces.joined(separator: " · ")
        } else {
            profileLabel.stringValue = String(localized: "Local listening history")
        }

        refreshPlayQueues(data, index: RecapLibraryIndex(albums: Library.shared.albums, tracks: Library.shared.allTracks))
        renderStats(data)
        renderArtists(data)
        renderAlbums(data)
        renderTracks(data)

        clockView.configure(buckets: data.listeningClock, tint: accent)
        heatmapView.configure(
            counts: data.calendarHeatmap ?? data.heatmap, tint: accent, dimBefore: Self.dimmingStart(for: data.period)
        )
        streakLabel.stringValue = data.streak > 0
            ? String(localized: "\(data.streak) days in a row and counting")
            : String(localized: "No active streak — press play to start one")

        personaTitleLabel.stringValue = RecapPersona.title(for: data.persona)
        personaBlurbLabel.stringValue = RecapPersona.blurb(for: data.persona)
        personaIcon.image = NSImage(systemSymbolName: RecapPersona.symbol(for: data.persona), accessibilityDescription: nil)
        personaIcon.contentTintColor = accent
    }

    /// Where dimming starts on the heatmap: a period of a year or more fills
    /// the calendar, so only the shorter ones leave earlier days faded.
    private static func dimmingStart(for period: ChartPeriod) -> Date? {
        switch period {
        case .week, .month, .threeMonths, .sixMonths: period.cutoffDate
        case .year, .allTime: nil
        }
    }

    private func renderStats(_ data: RecapData) {
        statsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let tiles: [(String, String, String, NSView?)] = [
            (
                RecapFormat.count(data.totalPlays), String(localized: "PLAYS"), "play.circle.fill",
                deltaChip(
                    current: data.totalPlays, previous: data.previousPlays, spanDays: data.previousSpanDays,
                    tooltip: { String(localized: "\(RecapFormat.count($0)) plays · \(RecapFormat.count($1)) in the previous \($2) days") }
                )
            ),
            (
                RecapFormat.count(data.totalMinutes), String(localized: "MINUTES"), "clock.fill",
                deltaChip(
                    current: data.totalMinutes, previous: data.previousMinutes, spanDays: data.previousSpanDays,
                    tooltip: { String(localized: "\(RecapFormat.count($0)) minutes · \(RecapFormat.count($1)) in the previous \($2) days") }
                )
            ),
            ("\(data.streak)", String(localized: "DAY STREAK"), "flame.fill", nil),
            (RecapPersona.title(for: data.persona), String(localized: "PERSONA"), RecapPersona.symbol(for: data.persona), nil),
        ]
        for (value, caption, symbol, chip) in tiles {
            statsRow.addArrangedSubview(statTile(value: value, caption: caption, symbol: symbol, chip: chip))
        }
    }

    /// The comparison pill for a tile, absent for All Time (nothing precedes
    /// it) and when neither window had any plays.
    private func deltaChip(
        current: Int, previous: Int?, spanDays: Int?, tooltip: (Int, Int, Int) -> String
    ) -> NSView? {
        guard let previous, let spanDays else { return nil }
        let chip = MacDeltaChipView(delta: PeriodDelta.compare(current: current, previous: previous), accent: accent)
        chip?.toolTip = tooltip(current, previous, spanDays)
        return chip
    }

    private func statTile(value: String, caption: String, symbol: String, chip: NSView?) -> NSView {
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
        let valueRow = NSStackView(views: [valueLabel] + (chip.map { [$0] } ?? []))
        valueRow.orientation = .horizontal
        valueRow.alignment = .centerY
        valueRow.spacing = 8
        let stack = NSStackView(views: [icon, valueRow, captionLabel])
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
            if album != nil {
                row.clickAction = { [weak self] in self?.startStation(artist: artist.name) }
            }
            row.menuProvider = { [weak self] in self?.artistMenu(name: artist.name, index: index, anchor: row) }
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
                row.clickAction = { [weak self] in self?.play(track: local) }
                row.menuProvider = { MacTrackMenuFactory.menu(for: local, anchor: row) }
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
        let detail = NSTextField(labelWithString: String(localized: "\(album.artistName) · \(RecapFormat.compact(album.playCount)) plays"))
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = MacColors.secondaryLabel
        detail.lineBreakMode = .byTruncatingTail

        let stack = ClickableStackView(views: [artwork, name, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        artwork.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let local {
            stack.clickAction = { AudioPlayer.shared.play(local.tracks, startingAt: 0) }
            stack.menuProvider = { MacTrackMenuFactory.menu(for: local, anchor: stack) }
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

        let playsLabel = NSTextField(labelWithString: String(localized: "\(RecapFormat.compact(plays)) plays"))
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

    private func play(track: Track) {
        let queue = playQueues[.tracks] ?? []
        guard let start = queue.firstIndex(where: { $0.fileURL == track.fileURL }) else { return }
        MidgarLog.info("Recap play track: \(track.title)", category: .playback)
        AudioPlayer.shared.play(queue, startingAt: start)
    }

    private func startStation(artist: String) {
        MidgarLog.info("Recap start station: \(artist)", category: .playback)
        AudioPlayer.shared.startStation(seedArtist: artist)
        MacToast.show(String(localized: "Station started from \(artist)"), style: .success, in: view.window)
    }

    private func artistMenu(name: String, index: RecapLibraryIndex, anchor: NSView) -> NSMenu {
        let menu = NSMenu()
        let tracks = index.tracks(byArtist: name)
        menu.addItem(ClosureMenuItem(title: String(localized: "View Artist"), systemImage: "music.microphone") {
            LibraryNavigator.revealArtist(name)
        })
        guard !tracks.isEmpty else { return menu }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: String(localized: "Play All"), systemImage: "play.fill") {
            AudioPlayer.shared.play(tracks, startingAt: 0)
        })
        menu.addItem(ClosureMenuItem(title: String(localized: "Shuffle All"), systemImage: "shuffle") {
            AudioPlayer.shared.play(tracks.shuffled(), startingAt: 0)
        })
        menu.addItem(ClosureMenuItem(title: String(localized: "Start Station"), systemImage: "dot.radiowaves.left.and.right") {
            AudioPlayer.shared.startStation(seedArtist: name)
            MacToast.show(String(localized: "Station started from \(name)"), style: .success, in: anchor.window)
        })
        return menu
    }

    private func renderSyncStatus(_ status: ListenHistoryStatus) {
        syncBanner.isHidden = !status.isBackfilling
        guard status.isBackfilling else {
            syncSpinner.stopAnimation(nil)
            return
        }
        syncLabel.stringValue = status.summary
        syncSpinner.startAnimation(nil)
    }

    /// Shows `period`, the way Home's Open Recap link lands on the last week.
    func show(period: ChartPeriod) {
        guard let index = ChartPeriod.allCases.firstIndex(of: period) else { return }
        periodPicker.selectedSegment = index
        viewModel.load(period: period)
    }

    #if DEBUG
    func selectPeriodForCapture(_ period: ChartPeriod) {
        show(period: period)
    }

    func scrollToBottomForCapture() {
        view.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, documentView.bounds.height - clip.bounds.height)))
        scrollView.reflectScrolledClipView(clip)
    }
    #endif

    @objc private func periodChanged() {
        let index = periodPicker.selectedSegment
        guard index >= 0, index < ChartPeriod.allCases.count else { return }
        viewModel.load(period: ChartPeriod.allCases[index])
    }

    @objc private func shareTapped() {
        guard let data = viewModel.data else { return }
        let palette = ArtworkPaletteExtractor.fallbackPalette(seed: data.persona + data.period.rawValue)
        guard let image = RecapShareCardRenderer.makeImage(data: data, palette: palette) else {
            MacToast.show(String(localized: "Couldn't draw the recap card — the system couldn't allocate its image. Try again."), style: .error, in: view.window)
            return
        }
        let menu = NSMenu()
        let share = menu.addItem(withTitle: String(localized: "Share…"), action: #selector(shareImage(_:)), keyEquivalent: "")
        share.target = self
        share.representedObject = image
        let save = menu.addItem(withTitle: String(localized: "Save PNG…"), action: #selector(saveImage(_:)), keyEquivalent: "")
        save.target = self
        save.representedObject = image
        let copy = menu.addItem(withTitle: String(localized: "Copy Image"), action: #selector(copyImage(_:)), keyEquivalent: "")
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
                MidgarLog.info("Recap share card saved to \(url.path)", category: .ui)
            } catch {
                MidgarLog.error("Recap card save failed: \(error.localizedDescription)", category: .ui)
            }
        }
    }

    @objc private func copyImage(_ sender: NSMenuItem) {
        guard let image = sender.representedObject as? NSImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        MacToast.show(String(localized: "Recap card copied"), style: .success, in: view.window)
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
    var menuProvider: (() -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        if clickAction != nil {
            clickAction?()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }

    override func resetCursorRects() {
        if clickAction != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}
