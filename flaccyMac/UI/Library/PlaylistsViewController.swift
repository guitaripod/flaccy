import AppKit

/// Playlist list: stacked-artwork mosaics, create/rename/delete via header
/// button and context menu, double-click to open the reorderable detail.
final class PlaylistsViewController: NSViewController {

    var onOpenPlaylist: ((PlaylistRecord) -> Void)?

    private struct Entry {
        let record: PlaylistRecord
        let trackCount: Int
        let tracks: [Track]
        var totalDuration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }
        var createdAt: Date { record.createdAt }
    }

    private enum Column: String {
        case playlist, count, duration, created
    }

    private let scrollView = NSScrollView()
    private let tableView = SongsTableView()
    private let emptyStateView = NSStackView()
    private var entries: [Entry] = []
    private var searchQuery = LibrarySearchState.query
    private var reloadGeneration = 0
    private var searchDebounce: Task<Void, Never>?
    private var sortColumn: Column = .created
    private var sortAscending = false

    override func loadView() {
        view = NSView()

        tableView.style = .inset
        tableView.rowHeight = 64
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.onDeleteRows = { [weak self] indexes in
            self?.confirmDeleteRows(indexes)
        }
        tableView.menuProvider = { [weak self] row in
            self?.contextMenu(forRow: row)
        }

        let columns: [(Column, String, CGFloat, CGFloat)] = [
            (.playlist, "Playlist", 320, 160),
            (.count, "Songs", 64, 48),
            (.duration, "Time", 80, 56),
            (.created, "Added", 130, 90),
        ]
        for (column, title, width, minWidth) in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = title
            tableColumn.width = width
            tableColumn.minWidth = minWidth
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            tableView.addTableColumn(tableColumn)
        }
        tableView.autosaveName = "flaccy.mac.playlistsTable"
        tableView.autosaveTableColumns = true
        tableView.sortDescriptors = [NSSortDescriptor(key: sortColumn.rawValue, ascending: sortAscending)]

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Playlists")
        title.font = .systemFont(ofSize: 20, weight: .bold)

        let newButton = GlassCapsuleButton(title: "New Playlist", symbolName: "plus")
        newButton.onClick = { [weak self] in
            PlaylistActions.promptForNewPlaylist(adding: [], in: self?.view.window)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, spacer, newButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(scrollView)

        buildEmptyState()
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: .flaccyPlaylistsDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload), name: Library.didUpdateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(searchQueryChanged(_:)), name: .flaccySearchQueryChanged, object: nil
        )
        reload()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        searchDebounce?.cancel()
    }

    /// The library-path join and per-playlist track fetches run off the main
    /// actor (the fetch contends with background sync writes on the database
    /// queue); a generation token drops stale results.
    @objc private func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let allTracks = Library.shared.allTracks
        let query = searchQuery
        Task.detached(priority: .userInitiated) { [weak self] in
            let entries = Self.fetchEntries(allTracks: allTracks, searchQuery: query)
            await MainActor.run { [weak self] in
                guard let self, self.reloadGeneration == generation else { return }
                self.entries = self.sortedEntries(entries)
                self.tableView.reloadData()
                self.emptyStateView.isHidden = !entries.isEmpty || !query.isEmpty
                AppLogger.debug("Playlists list showing \(entries.count) playlists", category: .ui)
            }
        }
    }

    nonisolated private static func fetchEntries(allTracks: [Track], searchQuery: String) -> [Entry] {
        let tracksByPath = Dictionary(
            allTracks.map { (LibraryPathResolver.relativePath(for: $0.fileURL), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        do {
            let records = try DatabaseManager.shared.fetchAllPlaylists()
            let query = searchQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return try records.compactMap { record in
                guard let id = record.id else { return nil }
                if !query.isEmpty {
                    let folded = record.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    guard folded.contains(query) else { return nil }
                }
                let playlistTracks = try DatabaseManager.shared.fetchPlaylistTracks(playlistId: id)
                let resolved = playlistTracks.compactMap { tracksByPath[canonicalSyncPath($0.trackFileURL)] }
                return Entry(record: record, trackCount: playlistTracks.count, tracks: resolved)
            }
        } catch {
            AppLogger.error("Playlist fetch failed: \(error.localizedDescription)", category: .database)
            return []
        }
    }

    @objc private func searchQueryChanged(_ notification: Notification) {
        searchQuery = notification.userInfo?[LibraryNavigator.Key.query] as? String ?? ""
        searchDebounce?.cancel()
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    private func sortedEntries(_ entries: [Entry]) -> [Entry] {
        let ascending = sortAscending
        func by<V: Comparable>(_ key: (Entry) -> V) -> [Entry] {
            entries.sorted {
                let a = key($0), b = key($1)
                if a == b { return $0.record.name.localizedCaseInsensitiveCompare($1.record.name) == .orderedAscending }
                return ascending ? a < b : a > b
            }
        }
        switch sortColumn {
        case .playlist:
            return entries.sorted {
                let cmp = $0.record.name.localizedCaseInsensitiveCompare($1.record.name)
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        case .count: return by { $0.trackCount }
        case .duration: return by { $0.totalDuration }
        case .created: return by { $0.createdAt }
        }
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        onOpenPlaylist?(entries[row].record)
    }

    private func confirmDeleteRows(_ indexes: IndexSet) {
        let records = indexes.compactMap { $0 < entries.count ? entries[$0].record : nil }
        guard !records.isEmpty else { return }
        if records.count == 1 {
            confirmDelete(records[0])
        } else {
            confirmDeleteMultiple(records)
        }
    }

    private func confirmDeleteMultiple(_ records: [PlaylistRecord]) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(records.count) playlists?"
        alert.informativeText = "The playlists are removed; your music files are not touched."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            for record in records {
                guard let id = record.id else { continue }
                try? DatabaseManager.shared.deletePlaylist(id: id)
            }
            AppLogger.info("Deleted \(records.count) playlists", category: .database)
            NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
        }
    }

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard row >= 0, row < entries.count else { return nil }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let entry = entries[row]
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Open", systemImage: "music.note.list") { [weak self] in
            self?.onOpenPlaylist?(entry.record)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Play", systemImage: "play.fill") {
            guard !entry.tracks.isEmpty else { return }
            AudioPlayer.shared.play(entry.tracks, startingAt: 0)
        })
        menu.addItem(ClosureMenuItem(title: "Shuffle", systemImage: "shuffle") {
            guard !entry.tracks.isEmpty else { return }
            AudioPlayer.shared.play(entry.tracks.shuffled(), startingAt: 0)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Rename…", systemImage: "pencil") { [weak self] in
            self?.promptRename(entry.record)
        })
        menu.addItem(ClosureMenuItem(title: "Delete…", systemImage: "trash") { [weak self] in
            self?.confirmDelete(entry.record)
        })
        return menu
    }

    private func promptRename(_ record: PlaylistRecord) {
        guard let id = record.id, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Playlist"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = record.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != record.name else { return }
            Self.rename(playlistId: id, from: record.name, to: name, in: window)
        }
    }

    /// DatabaseManager exposes no in-place rename, so renaming recreates the
    /// playlist under the new name with the same track order and drops the
    /// old row — the only playlist identity anywhere is the name shown.
    private static func rename(playlistId: Int64, from oldName: String, to newName: String, in window: NSWindow?) {
        do {
            let tracks = try DatabaseManager.shared.fetchPlaylistTracks(playlistId: playlistId)
            let renamed = try DatabaseManager.shared.createPlaylist(name: newName)
            guard let newId = renamed.id else { return }
            for track in tracks {
                try DatabaseManager.shared.addTrackToPlaylist(playlistId: newId, trackFileURL: track.trackFileURL)
            }
            try DatabaseManager.shared.deletePlaylist(id: playlistId)
            AppLogger.info("Playlist \(oldName) renamed to \(newName)", category: .database)
            NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
        } catch {
            AppLogger.error("Playlist rename failed: \(error.localizedDescription)", category: .database)
            MacToast.show("Couldn't rename playlist.", style: .error, in: window)
        }
    }

    private func confirmDelete(_ record: PlaylistRecord) {
        guard let id = record.id, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \u{201C}\(record.name)\u{201D}?"
        alert.informativeText = "The playlist is removed; your music files are not touched."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try DatabaseManager.shared.deletePlaylist(id: id)
                AppLogger.info("Playlist deleted: \(record.name)", category: .database)
                NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
            } catch {
                AppLogger.error("Playlist delete failed: \(error.localizedDescription)", category: .database)
                MacToast.show("Couldn't delete playlist.", style: .error, in: window)
            }
        }
    }

    private func buildEmptyState() {
        let icon = NSImageView(image: NSImage(
            systemSymbolName: "music.note.list", accessibilityDescription: nil
        ) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 44, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: "No Playlists Yet")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Create one here, or right-click any song and choose Add to Playlist.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        emptyStateView.setViews([icon, title, subtitle], in: .center)
        emptyStateView.orientation = .vertical
        emptyStateView.spacing = 10
        emptyStateView.alignment = .centerX
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
    }
}

extension PlaylistsViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let column = Column(rawValue: key) else { return }
        sortColumn = column
        sortAscending = descriptor.ascending
        entries = sortedEntries(entries)
        tableView.reloadData()
    }
}

extension PlaylistsViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count,
              let identifier = tableColumn?.identifier,
              let column = Column(rawValue: identifier.rawValue) else { return nil }
        let entry = entries[row]

        if column == .playlist {
            let cellID = NSUserInterfaceItemIdentifier("playlistCell")
            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? PlaylistCellView
                ?? PlaylistCellView(identifier: cellID)
            cell.configure(name: entry.record.name, trackCount: entry.trackCount, tracks: entry.tracks)
            return cell
        }

        let cellID = NSUserInterfaceItemIdentifier("plTextCell.\(column.rawValue)")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? TextCellView
            ?? TextCellView(identifier: cellID)
        cell.isDimmed = true
        switch column {
        case .count: cell.text = "\(entry.trackCount)"
        case .duration: cell.text = PlaybackFormat.duration(entry.totalDuration)
        case .created: cell.text = Self.dateFormatter.string(from: entry.createdAt)
        case .playlist: cell.text = ""
        }
        return cell
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

final class PlaylistCellView: NSTableCellView {

    private let mosaic = MosaicArtworkView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        mosaic.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [nameLabel, countLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mosaic)
        addSubview(labels)
        NSLayoutConstraint.activate([
            mosaic.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            mosaic.centerYAnchor.constraint(equalTo: centerYAnchor),
            mosaic.widthAnchor.constraint(equalToConstant: 52),
            mosaic.heightAnchor.constraint(equalToConstant: 52),

            labels.leadingAnchor.constraint(equalTo: mosaic.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, trackCount: Int, tracks: [Track]) {
        nameLabel.stringValue = name
        countLabel.stringValue = trackCount == 1 ? "1 song" : "\(trackCount) songs"
        mosaic.configure(with: tracks, fallbackSeed: name)
    }
}
