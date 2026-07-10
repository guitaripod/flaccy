import AppKit

/// Immersive artist page: circular photo header over a palette backdrop,
/// genre chips, library stats, Play All / Shuffle All / Start Station glass
/// capsules, Last.fm popular tracks matched against the library, an albums
/// shelf and a similar-artists row — forced dark like the album detail.
final class ArtistDetailViewController: NSViewController {

    var onOpenAlbum: ((Album) -> Void)?
    var onSelectArtist: ((String) -> Void)?

    private let artistName: String
    private let backdrop = AmbientBackdropView()
    private let scrollView = NSScrollView()
    private let photoTile = ArtworkTileView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let chipsRow = NSStackView()
    private let popularSection = NSStackView()
    private let popularTitle = NSTextField(labelWithString: "Popular")
    private let albumsShelf = AlbumShelfView()
    private let similarRow = SimilarArtistsRowView()
    private var albums: [Album] = []

    init(artist: String) {
        self.artistName = artist
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)

        let document = DetailDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false

        photoTile.cornerRadius = 80
        photoTile.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.stringValue = artistName
        nameLabel.font = .systemFont(ofSize: 30, weight: .bold)
        nameLabel.textColor = .white
        nameLabel.maximumNumberOfLines = 2

        statsLabel.font = .systemFont(ofSize: 12.5)
        statsLabel.textColor = NSColor.white.withAlphaComponent(0.6)

        chipsRow.orientation = .horizontal
        chipsRow.spacing = 8

        let playButton = GlassCapsuleButton(title: "Play All", symbolName: "play.fill", prominent: true)
        playButton.onClick = { [weak self] in self?.playAll(shuffled: false) }
        let shuffleButton = GlassCapsuleButton(title: "Shuffle All", symbolName: "shuffle")
        shuffleButton.onClick = { [weak self] in self?.playAll(shuffled: true) }
        let stationButton = GlassCapsuleButton(title: "Start Station", symbolName: "dot.radiowaves.left.and.right")
        stationButton.onClick = { [weak self] in self?.startStation() }
        let actions = NSStackView(views: [playButton, shuffleButton, stationButton])
        actions.orientation = .horizontal
        actions.spacing = 10

        let headerText = NSStackView(views: [nameLabel, statsLabel, chipsRow, actions])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 10
        headerText.setCustomSpacing(4, after: nameLabel)
        headerText.translatesAutoresizingMaskIntoConstraints = false

        popularTitle.font = .systemFont(ofSize: 15, weight: .bold)
        popularTitle.textColor = .white
        popularSection.orientation = .vertical
        popularSection.alignment = .leading
        popularSection.spacing = 0
        popularSection.translatesAutoresizingMaskIntoConstraints = false
        popularSection.isHidden = true

        albumsShelf.translatesAutoresizingMaskIntoConstraints = false
        albumsShelf.onOpenAlbum = { [weak self] album in self?.onOpenAlbum?(album) }

        similarRow.translatesAutoresizingMaskIntoConstraints = false
        similarRow.onSelectArtist = { [weak self] name in self?.onSelectArtist?(name) }

        document.addSubview(photoTile)
        document.addSubview(headerText)
        document.addSubview(popularSection)
        document.addSubview(albumsShelf)
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

            photoTile.topAnchor.constraint(equalTo: document.topAnchor, constant: 56),
            photoTile.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 32),
            photoTile.widthAnchor.constraint(equalToConstant: 160),
            photoTile.heightAnchor.constraint(equalToConstant: 160),

            headerText.leadingAnchor.constraint(equalTo: photoTile.trailingAnchor, constant: 28),
            headerText.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -32),
            headerText.centerYAnchor.constraint(equalTo: photoTile.centerYAnchor),

            popularSection.topAnchor.constraint(equalTo: photoTile.bottomAnchor, constant: 32),
            popularSection.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            popularSection.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),

            albumsShelf.topAnchor.constraint(equalTo: popularSection.bottomAnchor, constant: 32),
            albumsShelf.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 34),
            albumsShelf.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),

            similarRow.topAnchor.constraint(equalTo: albumsShelf.bottomAnchor, constant: 32),
            similarRow.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 34),
            similarRow.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -32),
            similarRow.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -32),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: Library.didUpdateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: AudioPlayer.trackDidChange, object: nil
        )
        refresh()
        loadPhotoAndPalette()
        loadEnrichment()
        similarRow.load(artist: artistName)
        AppLogger.info("Artist detail opened: \(artistName)", category: .ui)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func refresh() {
        albums = Library.shared.albums.filter { $0.artist == artistName }
        let trackCount = albums.reduce(0) { $0 + $1.tracks.count }
        statsLabel.stringValue =
            "\(albums.count) album\(albums.count == 1 ? "" : "s") · \(trackCount) song\(trackCount == 1 ? "" : "s") in your library"
        albumsShelf.configure(title: "Albums", albums: albums)
        rebuildPopular()
    }

    private var popularNames: [(name: String, playCount: Int, rank: Int)] = []

    private func rebuildPopular() {
        popularSection.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let libraryTracks = albums.flatMap(\.tracks)
        let matched: [(track: Track, rank: Int)] = popularNames.compactMap { popular in
            guard let track = libraryTracks.first(where: {
                $0.title.compare(popular.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) else { return nil }
            return (track, popular.rank)
        }
        guard !matched.isEmpty else {
            popularSection.isHidden = true
            return
        }
        popularSection.isHidden = false
        popularSection.addArrangedSubview(popularTitle)
        popularSection.setCustomSpacing(8, after: popularTitle)
        let queue = matched.map(\.track)
        let currentPath = AudioPlayer.shared.currentTrack?.fileURL
        for (index, entry) in matched.prefix(5).enumerated() {
            let row = DetailTrackRowView()
            row.configure(
                number: index + 1,
                title: entry.track.title,
                duration: entry.track.duration,
                loved: LovedTracksService.shared.isLoved(track: entry.track),
                isPlaying: currentPath == entry.track.fileURL
            )
            row.onDoubleClick = {
                AppLogger.info("Playing popular track \(entry.track.title)", category: .playback)
                AudioPlayer.shared.play(queue, startingAt: index)
            }
            row.onToggleLove = { [weak self] in
                Task {
                    _ = await LovedTracksService.shared.toggleLove(track: entry.track)
                    self?.rebuildPopular()
                }
            }
            row.onMenu = { [weak row] in
                MacTrackMenuFactory.menu(for: entry.track, anchor: row)
            }
            popularSection.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: popularSection.widthAnchor).isActive = true
        }
    }

    private func loadPhotoAndPalette() {
        photoTile.showPlaceholder(seed: artistName, shimmering: true)
        applyPalette(from: nil, animated: false)
        Task { [weak self] in
            guard let self else { return }
            if let photo = await MacArtistImageService.shared.image(for: self.artistName) {
                self.photoTile.showImage(photo)
                self.applyPalette(from: photo, animated: true)
            } else if let first = self.albums.first {
                AlbumArtworkCache.shared.loadThumbnail(
                    forAlbum: first.title, artist: first.artist
                ) { [weak self] image in
                    guard let self else { return }
                    if let image {
                        self.photoTile.showImage(image)
                        self.applyPalette(from: image, animated: true)
                    } else {
                        self.photoTile.stopShimmer()
                    }
                }
            } else {
                self.photoTile.stopShimmer()
            }
        }
    }

    private func applyPalette(from image: NSImage?, animated: Bool) {
        ArtworkPaletteExtractor.palette(
            for: image,
            cacheKey: "artist\u{0}\(artistName)",
            fallbackSeed: artistName
        ) { [weak self] palette in
            self?.backdrop.apply(palette, animated: animated)
        }
    }

    private func loadEnrichment() {
        let artist = artistName
        Task { [weak self] in
            let tags = await DetailEnrichmentCache.shared.topTags(artist: artist)
            guard let self else { return }
            self.chipsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for tag in tags.prefix(4) {
                self.chipsRow.addArrangedSubview(MacDetailChip.pill(text: tag, systemImage: nil))
            }
            self.chipsRow.isHidden = tags.isEmpty
        }
        Task { [weak self] in
            let popular = await DetailEnrichmentCache.shared.topTracks(artist: artist, limit: 12)
            guard let self else { return }
            self.popularNames = popular
            self.rebuildPopular()
        }
    }

    private func playAll(shuffled: Bool) {
        let tracks = albums.flatMap { $0.tracks.sorted { $0.trackNumber < $1.trackNumber } }
        guard !tracks.isEmpty else { return }
        AppLogger.info("Playing all by \(artistName) (shuffled: \(shuffled))", category: .playback)
        AudioPlayer.shared.play(shuffled ? tracks.shuffled() : tracks, startingAt: 0)
    }

    private func startStation() {
        AudioPlayer.shared.startStation(seedArtist: artistName)
        MacToast.show("Station started from \(artistName)", style: .success, in: view.window)
    }
}

/// Horizontal shelf of album cards used inside the artist detail; opens the
/// album detail on click and offers the canonical album context menu.
final class AlbumShelfView: NSView {

    var onOpenAlbum: ((Album) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        stack.orientation = .horizontal
        stack.spacing = 18
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = DetailDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        scrollView.documentView = document
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 196),

            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            document.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, albums: [Album]) {
        titleLabel.stringValue = title
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        isHidden = albums.isEmpty
        for album in albums {
            let card = AlbumShelfCard(album: album)
            card.onOpen = { [weak self] in self?.onOpenAlbum?(album) }
            stack.addArrangedSubview(card)
        }
    }
}

private final class AlbumShelfCard: NSView {

    var onOpen: (() -> Void)?

    private let album: Album
    private let tile = ArtworkTileView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let yearLabel = NSTextField(labelWithString: "")

    init(album: Album) {
        self.album = album
        super.init(frame: .zero)

        tile.cornerRadius = 10
        tile.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = album.title
        titleLabel.toolTip = album.title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        yearLabel.stringValue = album.year ?? ""
        yearLabel.font = .systemFont(ofSize: 11)
        yearLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        yearLabel.isHidden = album.year == nil

        let labels = NSStackView(views: [titleLabel, yearLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tile)
        addSubview(labels)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 140),
            tile.topAnchor.constraint(equalTo: topAnchor),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: trailingAnchor),
            tile.heightAnchor.constraint(equalTo: tile.widthAnchor),
            labels.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: 6),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        tile.showPlaceholder(seed: album.id, shimmering: true)
        let expected = album.id
        AlbumArtworkCache.shared.loadThumbnail(forAlbum: album.title, artist: album.artist) { [weak self] image in
            guard let self, self.album.id == expected else { return }
            if let image {
                self.tile.showImage(image)
            } else {
                self.tile.stopShimmer()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        onOpen?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        MacTrackMenuFactory.menu(for: album, anchor: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
