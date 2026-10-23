import AppKit
import MidgarCore
import FlaccyCore

/// Immersive album page: palette-driven ambient backdrop, artwork card,
/// metadata chips with Last.fm enrichment, glass play/shuffle capsules, the
/// songs in the layout the listener chose (list, table or columns, grouped by
/// disc) with loved hearts and playing indicator, and a similar-artists shelf,
/// following the system appearance. In a wide window the hero moves into a
/// rail of its own beside the scrolling songs.
final class AlbumDetailViewController: NSViewController {

    var onSelectArtist: ((String) -> Void)?

    private var album: Album
    private let backdrop = AmbientBackdropView()
    private let artworkTile = ArtworkTileView()
    private let coverOverlay = ArtworkEditOverlayView()
    private var artworkObserver: ArtworkChangeObserver?
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let artistButton = NSButton()
    private let metaLabel = NSTextField(labelWithString: "")
    private let metaPlaceholder = ShimmerLineView(width: 60, height: 13)
    private let chipsRow = NSStackView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let similarRow = SimilarArtistsRowView()
    private let model = TrackPageModel(kind: .album)
    private var pageFrame: TrackPageFrameView?
    private var songs: TrackPageSongs?
    private var isAwaitingMetadata = false

    init(album: Album) {
        self.album = album
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)

        artworkTile.cornerRadius = 14
        artworkTile.wantsLayer = true
        artworkTile.translatesAutoresizingMaskIntoConstraints = false
        coverOverlay.translatesAutoresizingMaskIntoConstraints = false
        let coverHost = NSView()
        coverHost.addSubview(artworkTile)
        coverHost.addSubview(coverOverlay)
        for layer in [artworkTile, coverOverlay] {
            NSLayoutConstraint.activate([
                layer.topAnchor.constraint(equalTo: coverHost.topAnchor),
                layer.leadingAnchor.constraint(equalTo: coverHost.leadingAnchor),
                layer.trailingAnchor.constraint(equalTo: coverHost.trailingAnchor),
                layer.bottomAnchor.constraint(equalTo: coverHost.bottomAnchor),
            ])
        }

        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = MacColors.primaryLabel
        titleLabel.maximumNumberOfLines = 2

        artistButton.isBordered = false
        artistButton.contentTintColor = MacColors.primaryLabel
        artistButton.font = .systemFont(ofSize: 16, weight: .medium)
        artistButton.target = self
        artistButton.action = #selector(artistClicked)
        artistButton.setButtonType(.momentaryChange)

        metaLabel.font = .systemFont(ofSize: 12.5)
        metaLabel.textColor = MacColors.secondaryLabel
        metaPlaceholder.isHidden = true

        chipsRow.orientation = .horizontal
        chipsRow.spacing = 8

        let playButton = GlassCapsuleButton(title: String(localized: "Play"), symbolName: "play.fill", prominent: true)
        playButton.onClick = { [weak self] in self?.play(shuffled: false) }
        let shuffleButton = GlassCapsuleButton(title: String(localized: "Shuffle"), symbolName: "shuffle")
        shuffleButton.onClick = { [weak self] in self?.play(shuffled: true) }
        let actions = MacLiquidGlass.buttonGroup([playButton, shuffleButton], spacing: 10)

        let headerText = NSStackView(views: [titleLabel, artistButton, metaLabel, metaPlaceholder, chipsRow, actions])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 10
        headerText.setCustomSpacing(4, after: titleLabel)

        footerLabel.font = .systemFont(ofSize: 12)
        footerLabel.textColor = MacColors.tertiaryLabel

        similarRow.onSelectArtist = { [weak self] name in
            self?.onSelectArtist?(name)
        }

        model.pageName = { [weak self] in self?.album.title ?? "" }
        let hero = TrackHeroView(cover: coverHost, text: headerText)
        let pageFrame = TrackPageFrameView(hero: hero)
        pageFrame.translatesAutoresizingMaskIntoConstraints = false
        let songs = TrackPageSongs(model: model, frame: pageFrame) { model in
            TrackBlocksSurface(model: model, columns: false)
        }
        similarRow.contentInset = 10
        let footer = NSStackView(views: [footerLabel])
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 0)
        pageFrame.setBody([songs.view, footer, similarRow])
        view.addSubview(pageFrame)
        self.pageFrame = pageFrame
        self.songs = songs

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            pageFrame.topAnchor.constraint(equalTo: view.topAnchor),
            pageFrame.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageFrame.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageFrame.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryUpdated), name: Library.didUpdateNotification, object: nil
        )
        configureCoverOverlay()
        artworkObserver = ArtworkChangeObserver { [weak self] in self?.refreshArtwork() }
        populate()
        loadArtworkAndPalette()
        similarRow.load(artist: album.artist)
        enrichOnAppear()
        MidgarLog.info("Album detail opened: \(album.title) — \(album.artist)", category: .ui)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        NotificationCenter.default.removeObserver(self, name: AudioPlayer.trackDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: LovedTracksService.didChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: AudioPlayer.playbackStateDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackChanged), name: AudioPlayer.trackDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(lovedChanged), name: LovedTracksService.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackChanged), name: AudioPlayer.playbackStateDidChange, object: nil
        )
        songs?.refreshPlaying()
        songs?.refreshLoved()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        NotificationCenter.default.removeObserver(self, name: AudioPlayer.trackDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: LovedTracksService.didChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: AudioPlayer.playbackStateDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func populate() {
        titleLabel.stringValue = album.title
        artistButton.title = album.artist

        var metaParts: [String] = []
        if let year = album.year, !year.isEmpty { metaParts.append(year) }
        if let genre = album.genre, !genre.isEmpty { metaParts.append(genre) }
        metaLabel.stringValue = metaParts.joined(separator: " · ")
        metaLabel.isHidden = metaParts.isEmpty || isAwaitingMetadata

        rebuildChips(playCount: DetailEnrichmentCache.shared.cachedAlbumPlayCount(
            artist: album.artist, album: album.title
        ))
        rebuildTracks()

        let totalSeconds = album.tracks.reduce(0.0) { $0 + $1.duration }
        footerLabel.stringValue = PlaybackFormat.songsAndMinutes(
            count: album.tracks.count, totalSeconds: totalSeconds
        )
    }

    private func rebuildChips(playCount: Int?) {
        chipsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let quality = DetailChip.albumQualitySummary(tracks: album.tracks) {
            chipsRow.addArrangedSubview(MacDetailChip.pill(text: quality, systemImage: "waveform"))
        }
        if let playCount, playCount > 0 {
            chipsRow.addArrangedSubview(MacDetailChip.pill(
                text: String(localized: "\(playCount) plays"), systemImage: "chart.bar.fill"
            ))
        }
        chipsRow.isHidden = chipsRow.arrangedSubviews.isEmpty
    }

    /// The album's songs in display order, with the disc each falls under when
    /// the release spans several.
    private func rebuildTracks() {
        let sorted = orderedTracks()
        let entries = sorted.enumerated().map { index, track in
            TrackPageEntry(
                track: track,
                number: track.trackNumber > 0 ? track.trackNumber : index + 1,
                rowID: nil
            )
        }
        songs?.update(entries: entries, sections: discSections(of: sorted))
    }

    private func orderedTracks() -> [Track] {
        TrackOrdering.ordered(
            album.tracks,
            number: { $0.trackNumber },
            path: { $0.fileURL.path },
            title: { $0.title }
        )
    }

    private func discSections(of sorted: [Track]) -> [TrackPageSection]? {
        guard let sections = TrackOrdering.sections(
            sorted, path: { LibraryPathResolver.relativePath(for: $0.fileURL) }
        ) else { return nil }
        var start = 0
        return sections.map { section in
            defer { start += section.items.count }
            return TrackPageSection(
                label: section.label,
                range: start..<(start + section.items.count),
                duration: section.items.reduce(0) { $0 + $1.duration }
            )
        }
    }

    private func loadArtworkAndPalette() {
        artworkTile.showPlaceholder(seed: album.id, shimmering: true)
        applyPaletteFromImage(nil, animated: false)
        let expected = album.id
        if let cached = AlbumArtworkCache.shared.nowPlayingArtwork(forAlbum: album.title, artist: album.artist) {
            artworkTile.showImage(cached)
            applyPaletteFromImage(cached, animated: false)
            return
        }
        AlbumArtworkCache.shared.loadNowPlayingArtwork(forAlbum: album.title, artist: album.artist) { [weak self] image in
            guard let self, self.album.id == expected else { return }
            if let image {
                self.artworkTile.showImage(image)
                self.applyPaletteFromImage(image, animated: true)
            } else {
                self.artworkTile.stopShimmer()
            }
        }
    }

    #if DEBUG
    var debugShownImage: CGImage? { artworkTile.displayedImage }
    var debugSongs: TrackPageSongs? { songs }
    #endif

    private func configureCoverOverlay() {
        coverOverlay.onEdit = { [weak self] in
            guard let self else { return }
            MacArtworkEditor.present(for: self.album, from: self.view.window)
        }
        coverOverlay.onDrop = { [weak self] input in
            guard let self else { return }
            MacArtworkEditor.present(for: self.album, initial: input, from: self.view.window)
        }
        coverOverlay.onMenu = { [weak self, weak coverOverlay] in
            guard let self else { return nil }
            return MacTrackMenuFactory.menu(for: self.album, anchor: coverOverlay, includeViewAlbum: false)
        }
    }

    /// Repaints the cover and the colours derived from it after the person
    /// changed it, keeping the old picture up until the new one has decoded so
    /// the header never flashes its placeholder.
    private func refreshArtwork() {
        let expected = album.id
        AlbumArtworkCache.shared.loadNowPlayingArtwork(forAlbum: album.title, artist: album.artist) { [weak self] image in
            guard let self, self.album.id == expected else { return }
            if let image {
                self.artworkTile.showImage(image)
                self.applyPaletteFromImage(image, animated: true)
            } else {
                self.artworkTile.showPlaceholder(seed: self.album.id, shimmering: false)
                self.applyPaletteFromImage(nil, animated: true)
            }
        }
    }

    private func applyPaletteFromImage(_ image: NSImage?, animated: Bool) {
        ArtworkPaletteExtractor.palette(
            for: image,
            cacheKey: "\(album.title)\u{0}\(album.artist)",
            fallbackSeed: album.id
        ) { [weak self] palette in
            self?.backdrop.apply(palette, animated: animated)
        }
    }

    /// Repairs this album's metadata when the queue says it is due, jumping it
    /// ahead of the background pass so the page the reader is looking at is
    /// fixed first and the result is persisted with everything else the job
    /// knows — no second write path, and no attempt charged for merely arriving
    /// on the page. An album the ladder has settled or given up on stays that
    /// way until the reader asks for it by name.
    private func enrichOnAppear() {
        let title = album.title
        let artist = album.artist
        Task { [weak self] in
            let playCount = await DetailEnrichmentCache.shared.albumPlayCount(artist: artist, album: title)
            guard let self, self.album.title == title else { return }
            self.rebuildChips(playCount: playCount)
        }
        guard album.year == nil || album.genre == nil else { return }
        guard isEnrichmentDue(title: title, artist: artist) else {
            renderUnresolvedMetadata(title: title, artist: artist)
            return
        }
        setAwaitingMetadata(true)
        Task { [weak self] in
            _ = await EnrichmentCoordinator.shared.requestNow(title: title, artist: artist)
            guard let self, self.album.title == title else { return }
            self.setAwaitingMetadata(false)
            let resolved = self.storedMetadata(title: title, artist: artist)
            guard resolved.year != nil || resolved.genre != nil else {
                self.renderUnresolvedMetadata(title: title, artist: artist)
                return
            }
            self.album = Album(
                title: self.album.title,
                artist: self.album.artist,
                artwork: self.album.artwork,
                tracks: self.album.tracks,
                year: resolved.year ?? self.album.year,
                genre: resolved.genre ?? self.album.genre
            )
            self.populate()
        }
    }

    /// Whether a page open is worth a network attempt. This is a presentation
    /// decision, not a second gate — the authoritative one is the single
    /// `EnrichmentPolicy.isDue` call inside the album task — but reading it here
    /// keeps a settled album from flashing a shimmer for a frame on its way to
    /// showing nothing.
    private func isEnrichmentDue(title: String, artist: String) -> Bool {
        let record = (try? DatabaseManager.shared.fetchEnrichmentRecord(
            scope: .album, key: EnrichmentKey.album(title: title, artist: artist)
        )) ?? nil
        return EnrichmentPolicy.isDue(record, scope: .album, now: Date())
    }

    private func storedMetadata(title: String, artist: String) -> (year: String?, genre: String?) {
        do {
            let status = try DatabaseManager.shared.fetchAlbumInfoStatus(title: title, artist: artist)
            return (status.year, status.genre)
        } catch {
            MidgarLog.error("Album metadata read failed: \(error.localizedDescription)", category: .database)
            return (nil, nil)
        }
    }

    /// Nothing came back. A source that answered and had nothing says so by
    /// staying silent — an absent year is not worth a sentence — but a lookup
    /// that never reached a source is the reader's network, and saying so is the
    /// difference between "this album is obscure" and "you are offline".
    private func renderUnresolvedMetadata(title: String, artist: String) {
        let record = (try? DatabaseManager.shared.fetchEnrichmentRecord(
            scope: .album, key: EnrichmentKey.album(title: title, artist: artist)
        )) ?? nil
        guard record?.lastFailure == .transport else { return }
        metaLabel.stringValue = String(localized: "Couldn't reach the metadata sources. Year and genre will load once you're online.")
        metaLabel.textColor = MacColors.tertiaryLabel
        metaLabel.isHidden = false
    }

    private func setAwaitingMetadata(_ awaiting: Bool) {
        isAwaitingMetadata = awaiting
        metaPlaceholder.isHidden = !awaiting
        metaPlaceholder.setShimmering(awaiting)
        if awaiting {
            metaLabel.isHidden = true
        } else {
            metaLabel.textColor = MacColors.secondaryLabel
            metaLabel.isHidden = metaLabel.stringValue.isEmpty
        }
    }

    private func play(shuffled: Bool) {
        let sorted = orderedTracks()
        guard !sorted.isEmpty else { return }
        MidgarLog.info("Playing album \(album.title) (shuffled: \(shuffled))", category: .playback)
        AudioPlayer.shared.play(shuffled ? sorted.shuffled() : sorted, startingAt: 0)
    }

    @objc private func artistClicked() {
        onSelectArtist?(album.artist)
    }

    @objc private func playbackChanged() {
        guard view.window != nil else { return }
        songs?.refreshPlaying()
    }

    @objc private func lovedChanged() {
        guard view.window != nil else { return }
        songs?.refreshLoved()
    }

    @objc private func libraryUpdated() {
        guard let refreshed = Library.shared.albums.first(where: { $0 == self.album }) else { return }
        album = refreshed
        pageFrame?.preservingScroll { populate() }
    }
}

/// A single line of text that has not arrived yet: the same sweeping highlight
/// `ArtworkTileView` uses for a decoding cover, sized to the line it stands in
/// for so the header does not reflow when the real words land.
final class ShimmerLineView: NSView {

    private let fillLayer = CALayer()
    private let shimmerLayer = CAGradientLayer()
    private let size: NSSize

    init(width: CGFloat, height: CGFloat) {
        size = NSSize(width: width, height: height)
        super.init(frame: NSRect(origin: .zero, size: size))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = height / 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        fillLayer.backgroundColor = MacColors.fill(0.14, light: 0.10).cgColor
        layer?.addSublayer(fillLayer)

        shimmerLayer.colors = [
            MacColors.fill(0, light: 0).cgColor,
            MacColors.fill(0.22, light: 0.16).cgColor,
            MacColors.fill(0, light: 0).cgColor,
        ]
        shimmerLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmerLayer.locations = [0, 0.5, 1]
        shimmerLayer.isHidden = true
        layer?.addSublayer(shimmerLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { size }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = bounds
        shimmerLayer.frame = bounds
        CATransaction.commit()
    }

    func setShimmering(_ shimmering: Bool) {
        let animate = shimmering && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        shimmerLayer.isHidden = !animate
        guard animate else {
            shimmerLayer.removeAnimation(forKey: "shimmer")
            return
        }
        guard shimmerLayer.animation(forKey: "shimmer") == nil else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-1.0, -0.5, 0.0]
        sweep.toValue = [1.0, 1.5, 2.0]
        sweep.duration = 1.35
        sweep.repeatCount = .infinity
        shimmerLayer.add(sweep, forKey: "shimmer")
    }
}
