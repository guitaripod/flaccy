import AppKit
import MidgarCore
import FlaccyCore

/// One playlist: a mosaic hero with play/shuffle capsules over its songs in
/// the layout the listener chose. The list layout reorders by drag, the table
/// is a sortable view of the same songs, and in a wide window the hero moves
/// into a rail beside the scrolling songs. Every removal and move is one
/// commit Edit > Undo takes back, songs the library lost can be taken out in
/// one go, and the Suggested Songs shelf under the list offers songs from the
/// person's own library.
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
    private var missingIds: [Int64] = []
    private let missingBar = NSStackView()
    private let missingLabel = NSTextField(labelWithString: "")
    private let suggestionsView = MacPlaylistSuggestionsView()
    private var suggestionsBasis: Set<String> = []
    private var suggestionsPage = 0
    private var suggestionsTask: Task<Void, Never>?

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
        configureMissingBar()
        configureSuggestions()
        pageFrame.setBody([songs.view, emptyLabel, missingBar, suggestionsView])
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(suggestionsSettingChanged), name: PlaylistSuggestionsSetting.didChange, object: nil
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
            let kept = Set(rows.compactMap(\.record.id))
            missingIds = records.compactMap(\.id).filter { !kept.contains($0) }
        } catch {
            MidgarLog.error("Playlist tracks fetch failed: \(error.localizedDescription)", category: .database)
            rows = []
            missingIds = []
        }
        render()
        reloadSuggestionsIfPlaylistChanged()
        MidgarLog.debug("Playlist detail \(playlist.name): \(rows.count) rows", category: .ui)
    }

    /// Paints the hero and the songs from `rows`, keeping the page where the
    /// reader scrolled it.
    private func render() {
        let totalSeconds = rows.reduce(0.0) { $0 + $1.track.duration }
        summaryLabel.stringValue = PlaylistCopy.summary(
            songs: rows.count + missingIds.count, seconds: totalSeconds, missing: missingIds.count
        )
        missingLabel.stringValue = String(localized: "\(missingIds.count) songs in this playlist are no longer in your library.")
        missingBar.isHidden = missingIds.isEmpty
        if let id = playlist.id {
            mosaic.configure(playlistId: id, tracks: rows.map(\.track), fallbackSeed: playlist.name)
        } else {
            mosaic.configure(with: rows.map(\.track), fallbackSeed: playlist.name)
        }
        emptyLabel.isHidden = !rows.isEmpty || !missingIds.isEmpty
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
        remove(ids: entries.compactMap(\.rowID))
    }

    /// Takes entries out in one commit; Edit > Undo and the toast's Undo put
    /// each song back where it stood.
    private func remove(ids: [Int64]) {
        guard let playlistId = playlist.id, !ids.isEmpty else { return }
        do {
            let removed = try DatabaseManager.shared.removePlaylistEntries(ids: ids, fromPlaylist: playlistId)
            MidgarLog.info("Removed \(removed.count) songs from a playlist", category: .database)
            NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
            let pending = PendingRestore(removed)
            registerUndo(name: PlaylistCopy.removeFromPlaylist) { controller in controller.restore(pending) }
            MacToast.showAction(PlaylistCopy.removed(removed.count), actionTitle: PlaylistCopy.undo, style: .success, in: view.window) { [weak self] in
                self?.restore(pending)
            }
        } catch {
            MidgarLog.error("Playlist row removal failed: \(error.localizedDescription)", category: .database)
            MacToast.show(PlaylistCopy.writeFailed(playlist.name), style: .error, in: view.window)
        }
    }

    /// Puts a removal back once, whichever of the toast's Undo and Edit >
    /// Undo asks first.
    private func restore(_ pending: PendingRestore) {
        guard let playlistId = playlist.id, !pending.isDone else { return }
        pending.isDone = true
        do {
            try DatabaseManager.shared.restorePlaylistEntries(pending.removed, toPlaylist: playlistId)
            NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
        } catch {
            MidgarLog.error("Playlist restore failed: \(error.localizedDescription)", category: .database)
            MacToast.show(PlaylistCopy.writeFailed(playlist.name), style: .error, in: view.window)
        }
    }

    /// Moves the dragged rows to just above `row`, shows the new order at once
    /// and writes it in one commit Edit > Undo takes back.
    private func moveRows(_ sources: IndexSet, to row: Int) {
        guard let playlistId = playlist.id else { return }
        let sourceRows = sources.filter { rows.indices.contains($0) }
        guard !sourceRows.isEmpty else { return }
        let before = (try? DatabaseManager.shared.fetchPlaylistTracks(playlistId: playlistId))?.compactMap(\.id) ?? []
        let moving = Set(sourceRows.compactMap { rows[$0].record.id })
        let shown = rows.compactMap(\.record.id)
        let landing = row < shown.count ? before.firstIndex(of: shown[row]) ?? before.count : (shown.last.flatMap { before.firstIndex(of: $0) }.map { $0 + 1 } ?? before.count)
        let order = PlaylistEditing.moved(before, moving: moving, to: landing)
        let byId = Dictionary(rows.compactMap { row in row.record.id.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        rows = order.compactMap { byId[$0] }
        render()
        do {
            try DatabaseManager.shared.reorderPlaylist(playlistId: playlistId, orderedEntryIDs: order)
            registerUndo(name: String(localized: "Move Song")) { controller in
                try? DatabaseManager.shared.reorderPlaylist(playlistId: playlistId, orderedEntryIDs: before)
                NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
                controller.view.window?.undoManager?.setActionName(String(localized: "Move Song"))
            }
        } catch {
            MidgarLog.error("Playlist reorder failed: \(error.localizedDescription)", category: .database)
            MacToast.show(PlaylistCopy.writeFailed(playlist.name), style: .error, in: view.window)
        }
        NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
    }

    private func registerUndo(name: String, _ handler: @escaping (PlaylistDetailViewController) -> Void) {
        guard let undo = view.window?.undoManager else { return }
        undo.registerUndo(withTarget: self, handler: handler)
        undo.setActionName(name)
    }

    /// The line under the songs that names how many the library lost, with a
    /// button that takes them out.
    private func configureMissingBar() {
        missingLabel.font = .systemFont(ofSize: 12)
        missingLabel.textColor = MacColors.secondaryLabel
        let button = NSButton(title: String(localized: "Remove Missing Songs"), target: self, action: #selector(removeMissing))
        button.bezelStyle = .push
        button.controlSize = .small
        missingBar.setViews([missingLabel, button], in: .leading)
        missingBar.orientation = .horizontal
        missingBar.spacing = 10
        missingBar.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 0, right: 8)
        missingBar.isHidden = true
    }

    @objc private func removeMissing() {
        remove(ids: missingIds)
    }

    private func configureSuggestions() {
        suggestionsView.isHidden = true
        suggestionsView.onAdd = { [weak self] track in
            guard let self, let id = self.playlist.id else { return }
            PlaylistActions.add([track], toPlaylist: id, named: self.playlist.name, in: self.view.window)
        }
        suggestionsView.onRefresh = { [weak self] in
            guard let self else { return }
            self.suggestionsPage += 1
            self.loadSuggestions()
        }
        suggestionsView.onHide = { [weak self] in
            PlaylistSuggestionsSetting.setShown(false)
            MacToast.showAction(PlaylistCopy.hideSuggestions, actionTitle: PlaylistCopy.undo, in: self?.view.window) {
                PlaylistSuggestionsSetting.setShown(true)
            }
        }
    }

    @objc private func suggestionsSettingChanged() {
        suggestionsBasis = []
        reloadSuggestionsIfPlaylistChanged()
    }

    /// Builds the shelf again when the playlist's songs changed, so an added
    /// suggestion makes room for the next one.
    private func reloadSuggestionsIfPlaylistChanged() {
        guard PlaylistSuggestionsSetting.isShown, !rows.isEmpty else {
            suggestionsTask?.cancel()
            suggestionsBasis = []
            suggestionsView.show([])
            return
        }
        let basis = Set(rows.map(\.record.trackFileURL))
        guard basis != suggestionsBasis else { return }
        suggestionsBasis = basis
        loadSuggestions()
    }

    private func loadSuggestions() {
        suggestionsTask?.cancel()
        let playlist = rows.map(\.track)
        let library = Library.shared.allTracks
        let page = suggestionsPage
        suggestionsTask = Task { [weak self] in
            var shown: [URL]?
            for cachedOnly in [true, false] {
                let found = await Task.detached(priority: .utility) {
                    await PlaylistSuggestionLoader.suggestions(for: playlist, library: library, page: page, cachedOnly: cachedOnly)
                }.value
                guard !Task.isCancelled, let self, PlaylistSuggestionsSetting.isShown else { return }
                guard found.map(\.fileURL) != shown else { continue }
                shown = found.map(\.fileURL)
                self.pageFrame?.preservingScroll { self.suggestionsView.show(found) }
            }
        }
    }

    #if DEBUG
    var debugSongs: TrackPageSongs? { songs }
    #endif
}
