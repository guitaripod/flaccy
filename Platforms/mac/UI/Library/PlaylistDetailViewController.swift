import AppKit
import MidgarCore
import FlaccyCore

/// One playlist: a mosaic hero with play/shuffle capsules over its songs in
/// the layout the listener chose. The list layout reorders by drag, the table
/// is a sortable view of the same songs, and in a wide window the hero moves
/// into a rail beside the scrolling songs.
final class PlaylistDetailViewController: NSViewController {

    private struct Row {
        let record: PlaylistTrackRecord
        let track: Track
    }

    private let playlist: PlaylistRecord
    private let mosaic = MosaicArtworkView()
    private let coverOverlay = ArtworkEditOverlayView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: String(localized: "No songs yet. Right-click any song and choose Add to Playlist."))
    private let model = TrackPageModel(kind: .playlist)
    private var pageFrame: TrackPageFrameView?
    private var songs: TrackPageSongs?
    private var rows: [Row] = []

    init(playlist: PlaylistRecord) {
        self.playlist = playlist
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()

        mosaic.translatesAutoresizingMaskIntoConstraints = false
        coverOverlay.translatesAutoresizingMaskIntoConstraints = false
        configureCoverOverlay()
        let coverHost = NSView()
        coverHost.addSubview(mosaic)
        coverHost.addSubview(coverOverlay)
        for layer in [mosaic, coverOverlay] {
            NSLayoutConstraint.activate([
                layer.topAnchor.constraint(equalTo: coverHost.topAnchor),
                layer.leadingAnchor.constraint(equalTo: coverHost.leadingAnchor),
                layer.trailingAnchor.constraint(equalTo: coverHost.trailingAnchor),
                layer.bottomAnchor.constraint(equalTo: coverHost.bottomAnchor),
            ])
        }

        nameLabel.stringValue = playlist.name
        nameLabel.font = .systemFont(ofSize: 28, weight: .bold)
        nameLabel.textColor = MacColors.primaryLabel
        nameLabel.maximumNumberOfLines = 2

        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor

        let playButton = GlassCapsuleButton(title: String(localized: "Play"), symbolName: "play.fill", prominent: true)
        playButton.onClick = { [weak self] in self?.play(shuffled: false) }
        let shuffleButton = GlassCapsuleButton(title: String(localized: "Shuffle"), symbolName: "shuffle")
        shuffleButton.onClick = { [weak self] in self?.play(shuffled: true) }
        let actions = MacLiquidGlass.buttonGroup([playButton, shuffleButton], spacing: 10)

        let meta = NSStackView(views: [nameLabel, summaryLabel, actions])
        meta.orientation = .vertical
        meta.alignment = .leading
        meta.spacing = 8

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = MacColors.secondaryLabel
        emptyLabel.isHidden = true

        model.pageName = { [weak self] in self?.playlist.name ?? "" }
        model.play = { [weak self] tracks, index in
            AudioPlayer.shared.play(tracks, startingAt: index, context: self?.playlist.playbackContext)
        }
        model.menu = { [weak self] entry, anchor in
            var options = MacTrackMenuFactory.TrackOptions()
            options.removeFromPlaylist = { [weak self] in
                self?.removeEntries([entry])
            }
            return MacTrackMenuFactory.menu(for: entry.track, anchor: anchor, options: options)
        }
        model.remove = { [weak self] entries in self?.removeEntries(entries) }
        model.reorder = { [weak self] sources, row in self?.moveRows(sources, to: row) }

        let hero = TrackHeroView(cover: coverHost, text: meta)
        let pageFrame = TrackPageFrameView(hero: hero)
        pageFrame.translatesAutoresizingMaskIntoConstraints = false
        let songs = TrackPageSongs(model: model, frame: pageFrame) { model in
            PlaylistListSurface(model: model)
        }
        songs.hint = { layout in
            layout == .table
                ? String(localized: "A table is a view of the playlist: switch to List to reorder · right-click to remove")
                : String(localized: "Drag rows to reorder · right-click to remove")
        }
        pageFrame.setBody([songs.view, emptyLabel])
        view.addSubview(pageFrame)
        self.pageFrame = pageFrame
        self.songs = songs

        NSLayoutConstraint.activate([
            pageFrame.topAnchor.constraint(equalTo: view.topAnchor),
            pageFrame.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageFrame.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageFrame.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: Library.didUpdateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .flaccyPlaylistsDidChange, object: nil
        )
        reload()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        stopObservingPlayback()
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackChanged), name: AudioPlayer.trackDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackChanged), name: AudioPlayer.playbackStateDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(lovedChanged), name: LovedTracksService.didChange, object: nil
        )
        songs?.refreshPlaying()
        songs?.refreshLoved()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stopObservingPlayback()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func stopObservingPlayback() {
        NotificationCenter.default.removeObserver(self, name: AudioPlayer.trackDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: AudioPlayer.playbackStateDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: LovedTracksService.didChange, object: nil)
    }

    @objc private func playbackChanged() {
        guard view.window != nil else { return }
        songs?.refreshPlaying()
    }

    @objc private func lovedChanged() {
        guard view.window != nil else { return }
        songs?.refreshLoved()
    }

    @objc private func reload() {
        guard let id = playlist.id else { return }
        let tracksByPath = Dictionary(
            Library.shared.allTracks.map { (LibraryPathResolver.relativePath(for: $0.fileURL), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        do {
            let records = try DatabaseManager.shared.fetchPlaylistTracks(playlistId: id)
            rows = records.compactMap { record in
                guard let track = tracksByPath[canonicalSyncPath(record.trackFileURL)] else { return nil }
                return Row(record: record, track: track)
            }
        } catch {
            MidgarLog.error("Playlist tracks fetch failed: \(error.localizedDescription)", category: .database)
            rows = []
        }
        render()
        MidgarLog.debug("Playlist detail \(playlist.name): \(rows.count) rows", category: .ui)
    }

    /// Paints the hero and the songs from `rows`, keeping the page where the
    /// reader scrolled it.
    private func render() {
        let totalSeconds = rows.reduce(0.0) { $0 + $1.track.duration }
        summaryLabel.stringValue = PlaybackFormat.songsAndMinutes(count: rows.count, totalSeconds: totalSeconds)
        if let id = playlist.id {
            mosaic.configure(playlistId: id, tracks: rows.map(\.track), fallbackSeed: playlist.name)
        } else {
            mosaic.configure(with: rows.map(\.track), fallbackSeed: playlist.name)
        }
        emptyLabel.isHidden = !rows.isEmpty
        let entries = rows.enumerated().map { index, row in
            TrackPageEntry(track: row.track, number: index + 1, rowID: row.record.id)
        }
        pageFrame?.preservingScroll {
            songs?.update(entries: entries, sections: nil)
        }
    }

    /// The cover's pencil, picture drop and context menu open the same editor
    /// the album page uses, over the playlist's own tracks.
    private func configureCoverOverlay() {
        coverOverlay.editLabel = String(localized: "Edit Cover")
        coverOverlay.ringCornerRadius = 8
        coverOverlay.onEdit = { [weak self] in
            guard let self else { return }
            MacArtworkEditor.present(forPlaylist: self.playlist, tracks: self.rows.map(\.track), from: self.view.window)
        }
        coverOverlay.onDrop = { [weak self] input in
            guard let self else { return }
            MacArtworkEditor.present(
                forPlaylist: self.playlist, tracks: self.rows.map(\.track), initial: input, from: self.view.window
            )
        }
        coverOverlay.onMenu = { [weak self] in
            guard let self else { return nil }
            let menu = NSMenu()
            MacArtworkEditor.coverMenuItems(for: self.playlist, tracks: self.rows.map(\.track), window: self.view.window)
                .forEach(menu.addItem)
            return menu
        }
    }

    private func play(shuffled: Bool) {
        let tracks = rows.map(\.track)
        guard !tracks.isEmpty else { return }
        MidgarLog.info("Playing playlist \(playlist.name) (shuffled: \(shuffled))", category: .playback)
        AudioPlayer.shared.play(shuffled ? tracks.shuffled() : tracks, startingAt: 0, context: playlist.playbackContext)
    }

    private func removeEntries(_ entries: [TrackPageEntry]) {
        let ids = entries.compactMap(\.rowID)
        guard !ids.isEmpty else { return }
        for id in ids {
            do {
                try DatabaseManager.shared.removeTrackFromPlaylist(id: id)
            } catch {
                MidgarLog.error("Playlist row removal failed: \(error.localizedDescription)", category: .database)
            }
        }
        MidgarLog.info("Removed \(ids.count) row(s) from playlist \(playlist.name)", category: .database)
        NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
    }

    /// Moves the dragged rows to just above `row`, shows the new order at once
    /// and writes only the positions that changed.
    private func moveRows(_ sources: IndexSet, to row: Int) {
        let sourceRows = sources.filter { rows.indices.contains($0) }.sorted()
        guard !sourceRows.isEmpty else { return }
        var reordered = rows
        let moved = sourceRows.map { rows[$0] }
        for source in sourceRows.reversed() {
            reordered.remove(at: source)
        }
        let insertionIndex = row - sourceRows.filter { $0 < row }.count
        reordered.insert(contentsOf: moved, at: insertionIndex)
        rows = reordered
        render()
        PlaylistActions.persistOrder(rows.map(\.record))
        NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
    }

    #if DEBUG
    var debugSongs: TrackPageSongs? { songs }
    #endif
}
