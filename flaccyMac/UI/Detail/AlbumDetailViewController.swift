import AppKit
import FlaccyCore

/// Immersive album page: palette-driven ambient backdrop, artwork card,
/// metadata chips with Last.fm enrichment, glass play/shuffle capsules, a
/// full track list with loved hearts and playing indicator, and a
/// similar-artists shelf, following the system appearance.
final class AlbumDetailViewController: NSViewController {

    var onSelectArtist: ((String) -> Void)?

    private var album: Album
    private let backdrop = AmbientBackdropView()
    private let scrollView = NSScrollView()
    private let artworkTile = ArtworkTileView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let artistButton = NSButton()
    private let metaLabel = NSTextField(labelWithString: "")
    private let metaPlaceholder = ShimmerLineView(width: 60, height: 13)
    private let chipsRow = NSStackView()
    private let tracksStack = NSStackView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let similarRow = SimilarArtistsRowView()
    private var trackRows: [DetailTrackRowView] = []
    private var rowTracks: [Track] = []
    private var rowByURL: [URL: DetailTrackRowView] = [:]
    private var playingURL: URL?
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

        let document = DetailDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false

        artworkTile.cornerRadius = 14
        artworkTile.wantsLayer = true
        artworkTile.translatesAutoresizingMaskIntoConstraints = false

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
        let actions = NSStackView(views: [playButton, shuffleButton])
        actions.orientation = .horizontal
        actions.spacing = 10

        let headerText = NSStackView(views: [titleLabel, artistButton, metaLabel, metaPlaceholder, chipsRow, actions])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 10
        headerText.setCustomSpacing(4, after: titleLabel)
        headerText.translatesAutoresizingMaskIntoConstraints = false

        tracksStack.orientation = .vertical
        tracksStack.spacing = 0
        tracksStack.translatesAutoresizingMaskIntoConstraints = false

        footerLabel.font = .systemFont(ofSize: 12)
        footerLabel.textColor = MacColors.tertiaryLabel
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        similarRow.translatesAutoresizingMaskIntoConstraints = false
        similarRow.onSelectArtist = { [weak self] name in
            self?.onSelectArtist?(name)
        }

        document.addSubview(artworkTile)
        document.addSubview(headerText)
        document.addSubview(tracksStack)
        document.addSubview(footerLabel)
        document.addSubview(similarRow)

        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            document.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            artworkTile.topAnchor.constraint(equalTo: document.topAnchor, constant: 56),
            artworkTile.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 32),
            artworkTile.widthAnchor.constraint(equalToConstant: 232),
            artworkTile.heightAnchor.constraint(equalToConstant: 232),

            headerText.leadingAnchor.constraint(equalTo: artworkTile.trailingAnchor, constant: 28),
            headerText.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -32),
            headerText.bottomAnchor.constraint(equalTo: artworkTile.bottomAnchor),
            headerText.topAnchor.constraint(greaterThanOrEqualTo: document.topAnchor, constant: 56),

            tracksStack.topAnchor.constraint(equalTo: artworkTile.bottomAnchor, constant: 28),
            tracksStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            tracksStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),

            footerLabel.topAnchor.constraint(equalTo: tracksStack.bottomAnchor, constant: 12),
            footerLabel.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 34),

            similarRow.topAnchor.constraint(equalTo: footerLabel.bottomAnchor, constant: 32),
            similarRow.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 34),
            similarRow.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -32),
            similarRow.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -32),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryUpdated), name: Library.didUpdateNotification, object: nil
        )
        populate()
        loadArtworkAndPalette()
        similarRow.load(artist: album.artist)
        enrichOnAppear()
        AppLogger.info("Album detail opened: \(album.title) — \(album.artist)", category: .ui)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        NotificationCenter.default.removeObserver(self, name: AudioPlayer.trackDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: LovedTracksService.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackChanged), name: AudioPlayer.trackDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(lovedChanged), name: LovedTracksService.didChange, object: nil
        )
        updatePlayingState()
        refreshLovedHearts()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        NotificationCenter.default.removeObserver(self, name: AudioPlayer.trackDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: LovedTracksService.didChange, object: nil)
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

    private func rebuildTracks() {
        trackRows.forEach { $0.removeFromSuperview() }
        trackRows = []
        rowTracks = []
        rowByURL = [:]
        let sorted = TrackOrdering.ordered(
            album.tracks,
            number: { $0.trackNumber },
            path: { $0.fileURL.path },
            title: { $0.title }
        )
        let currentPath = AudioPlayer.shared.currentTrack?.fileURL
        playingURL = currentPath
        for (index, track) in sorted.enumerated() {
            let row = DetailTrackRowView()
            row.configure(
                number: track.trackNumber > 0 ? track.trackNumber : index + 1,
                title: track.title,
                duration: track.duration,
                loved: LovedTracksService.shared.isLoved(track: track),
                isPlaying: currentPath == track.fileURL
            )
            row.onDoubleClick = { [weak self] in
                guard let self else { return }
                AppLogger.info("Playing \(track.title) from album detail", category: .playback)
                AudioPlayer.shared.play(sorted, startingAt: index)
            }
            row.onToggleLove = {
                Task { _ = await LovedTracksService.shared.toggleLove(track: track) }
            }
            row.onMenu = { [weak row] in
                MacTrackMenuFactory.menu(for: track, anchor: row)
            }
            tracksStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: tracksStack.widthAnchor).isActive = true
            trackRows.append(row)
            rowTracks.append(track)
            rowByURL[track.fileURL] = row
        }
    }

    private func updatePlayingState() {
        let newURL = AudioPlayer.shared.currentTrack?.fileURL
        guard newURL != playingURL else { return }
        if let old = playingURL { rowByURL[old]?.setPlaying(false) }
        if let new = newURL { rowByURL[new]?.setPlaying(true) }
        playingURL = newURL
    }

    private func refreshLovedHearts() {
        for (row, track) in zip(trackRows, rowTracks) {
            row.setLoved(LovedTracksService.shared.isLoved(track: track))
        }
    }

    private func loadArtworkAndPalette() {
        artworkTile.showPlaceholder(seed: album.id, shimmering: true)
        applyPaletteFromImage(nil, animated: false)
        let expected = album.id
        if let cached = AlbumArtworkCache.shared.artwork(forAlbum: album.title, artist: album.artist) {
            artworkTile.showImage(cached)
            applyPaletteFromImage(cached, animated: false)
            return
        }
        AlbumArtworkCache.shared.loadArtwork(forAlbum: album.title, artist: album.artist) { [weak self] image in
            guard let self, self.album.id == expected else { return }
            if let image {
                self.artworkTile.showImage(image)
                self.applyPaletteFromImage(image, animated: true)
            } else {
                self.artworkTile.stopShimmer()
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
            AppLogger.error("Album metadata read failed: \(error.localizedDescription)", category: .database)
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
        metaLabel.stringValue = String(localized: "Metadata unavailable offline")
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
        let sorted = TrackOrdering.ordered(
            album.tracks,
            number: { $0.trackNumber },
            path: { $0.fileURL.path },
            title: { $0.title }
        )
        guard !sorted.isEmpty else { return }
        AppLogger.info("Playing album \(album.title) (shuffled: \(shuffled))", category: .playback)
        AudioPlayer.shared.play(shuffled ? sorted.shuffled() : sorted, startingAt: 0)
    }

    @objc private func artistClicked() {
        onSelectArtist?(album.artist)
    }

    @objc private func playbackChanged() {
        guard view.window != nil else { return }
        updatePlayingState()
    }

    @objc private func lovedChanged() {
        guard view.window != nil else { return }
        refreshLovedHearts()
    }

    @objc private func libraryUpdated() {
        guard let refreshed = Library.shared.albums.first(where: { $0 == self.album }) else { return }
        album = refreshed
        populate()
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
