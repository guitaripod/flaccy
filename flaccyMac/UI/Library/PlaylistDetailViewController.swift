import AppKit

/// One playlist: mosaic header with play/shuffle capsules over a reorderable
/// track table — native drag reorder persists positions touching only the
/// rows that moved, delete removes rows, double-click plays the playlist.
final class PlaylistDetailViewController: NSViewController {

    private struct Row {
        let record: PlaylistTrackRecord
        let track: Track
    }

    private let playlist: PlaylistRecord
    private let scrollView = NSScrollView()
    private let tableView = SongsTableView()
    private let mosaic = MosaicArtworkView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private var rows: [Row] = []

    private static let dragType = NSPasteboard.PasteboardType("com.midgarcorp.flaccy.playlistRow")

    init(playlist: PlaylistRecord) {
        self.playlist = playlist
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()

        mosaic.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.stringValue = playlist.name
        nameLabel.font = .systemFont(ofSize: 24, weight: .bold)
        nameLabel.lineBreakMode = .byTruncatingTail

        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor

        let playButton = GlassCapsuleButton(title: "Play", symbolName: "play.fill", prominent: true)
        playButton.onClick = { [weak self] in self?.play(shuffled: false) }
        let shuffleButton = GlassCapsuleButton(title: "Shuffle", symbolName: "shuffle")
        shuffleButton.onClick = { [weak self] in self?.play(shuffled: true) }
        let actions = NSStackView(views: [playButton, shuffleButton])
        actions.orientation = .horizontal
        actions.spacing = 10

        let meta = NSStackView(views: [nameLabel, summaryLabel, actions])
        meta.orientation = .vertical
        meta.alignment = .leading
        meta.spacing = 8
        meta.translatesAutoresizingMaskIntoConstraints = false

        tableView.style = .inset
        tableView.rowHeight = 26
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.registerForDraggedTypes([Self.dragType])
        tableView.onDeleteRows = { [weak self] indexes in
            self?.removeRows(at: indexes)
        }
        tableView.menuProvider = { [weak self] row in
            self?.contextMenu(forRow: row)
        }

        let columns: [(String, String, CGFloat)] = [
            ("number", "#", 36),
            ("title", "Title", 280),
            ("artist", "Artist", 180),
            ("duration", "Time", 60),
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(mosaic)
        view.addSubview(meta)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            mosaic.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 52),
            mosaic.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            mosaic.widthAnchor.constraint(equalToConstant: 130),
            mosaic.heightAnchor.constraint(equalToConstant: 130),

            meta.leadingAnchor.constraint(equalTo: mosaic.trailingAnchor, constant: 20),
            meta.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
            meta.centerYAnchor.constraint(equalTo: mosaic.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: mosaic.bottomAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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

    deinit {
        NotificationCenter.default.removeObserver(self)
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
            AppLogger.error("Playlist tracks fetch failed: \(error.localizedDescription)", category: .database)
            rows = []
        }
        let totalSeconds = rows.reduce(0.0) { $0 + $1.track.duration }
        summaryLabel.stringValue = PlaybackFormat.songsAndMinutes(count: rows.count, totalSeconds: totalSeconds)
        mosaic.configure(with: rows.map(\.track), fallbackSeed: playlist.name)
        tableView.reloadData()
        AppLogger.debug("Playlist detail \(playlist.name): \(rows.count) rows", category: .ui)
    }

    private func play(shuffled: Bool) {
        let tracks = rows.map(\.track)
        guard !tracks.isEmpty else { return }
        AppLogger.info("Playing playlist \(playlist.name) (shuffled: \(shuffled))", category: .playback)
        AudioPlayer.shared.play(shuffled ? tracks.shuffled() : tracks, startingAt: 0)
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        AudioPlayer.shared.play(rows.map(\.track), startingAt: row)
    }

    private func removeRows(at indexes: IndexSet) {
        let victims = indexes.compactMap { $0 < rows.count ? rows[$0] : nil }
        guard !victims.isEmpty else { return }
        for victim in victims {
            guard let rowId = victim.record.id else { continue }
            do {
                try DatabaseManager.shared.removeTrackFromPlaylist(id: rowId)
            } catch {
                AppLogger.error("Playlist row removal failed: \(error.localizedDescription)", category: .database)
            }
        }
        AppLogger.info("Removed \(victims.count) row(s) from playlist \(playlist.name)", category: .database)
        NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
    }

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard row >= 0, row < rows.count else { return nil }
        if !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        var options = MacTrackMenuFactory.TrackOptions()
        options.removeFromPlaylist = { [weak self] in
            self?.removeRows(at: IndexSet(integer: row))
        }
        return MacTrackMenuFactory.menu(for: rows[row].track, anchor: tableView, options: options)
    }
}

extension PlaylistDetailViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString("\(row)", forType: Self.dragType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard dropOperation == .above else { return [] }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let items = info.draggingPasteboard.pasteboardItems else { return false }
        let sourceRows = items
            .compactMap { $0.string(forType: Self.dragType) }
            .compactMap(Int.init)
            .sorted()
        guard !sourceRows.isEmpty else { return false }

        var reordered = rows
        let moved = sourceRows.map { rows[$0] }
        for source in sourceRows.reversed() {
            reordered.remove(at: source)
        }
        let insertionIndex = row - sourceRows.filter { $0 < row }.count
        reordered.insert(contentsOf: moved, at: insertionIndex)
        rows = reordered
        tableView.reloadData()
        PlaylistActions.persistOrder(rows.map(\.record))
        NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
        return true
    }
}

extension PlaylistDetailViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row rowIndex: Int) -> NSView? {
        guard rowIndex < rows.count, let identifier = tableColumn?.identifier else { return nil }
        let row = rows[rowIndex]

        if identifier.rawValue == "title" {
            let cellID = NSUserInterfaceItemIdentifier("titleCell")
            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? PlayingTitleCellView
                ?? PlayingTitleCellView(identifier: cellID)
            cell.configure(
                title: row.track.title,
                isPlaying: AudioPlayer.shared.currentTrack?.fileURL == row.track.fileURL
            )
            return cell
        }

        let cellID = NSUserInterfaceItemIdentifier("textCell.\(identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? TextCellView
            ?? TextCellView(identifier: cellID)
        switch identifier.rawValue {
        case "number":
            cell.text = "\(rowIndex + 1)"
            cell.isDimmed = true
        case "artist":
            cell.text = row.track.artist
            cell.isDimmed = false
        case "duration":
            cell.text = PlaybackFormat.duration(row.track.duration)
            cell.isDimmed = true
        default:
            cell.text = ""
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier.rawValue == "title", row < rows.count else { return nil }
        return rows[row].track.title
    }
}
