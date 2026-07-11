import AppKit
import Combine

/// Multi-column sortable songs table: click-to-sort headers, type-select,
/// double-click plays the visible order as the queue context, delete-key
/// removal, per-row loved hearts and the canonical track context menu.
final class SongsTableViewController: NSViewController {

    private let viewModel = SongsTableViewModel()
    private let scrollView = NSScrollView()
    private let tableView = SongsTableView()
    private let emptyStateView = LibraryEmptyStateView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private var cancellables = Set<AnyCancellable>()
    private var rows: [SongsTableViewModel.Row] = []
    private var playingPath: String?
    private var isReseedingSort = false

    override func loadView() {
        view = NSView()

        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsTypeSelect = true
        tableView.rowHeight = 26
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.onDeleteRows = { [weak self] indexes in
            self?.deleteRows(at: indexes)
        }
        tableView.menuProvider = { [weak self] row in
            self?.contextMenu(forRow: row)
        }

        for column in SongsTableViewModel.Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.headerTitle
            tableColumn.width = column.initialWidth
            tableColumn.minWidth = 40
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            tableView.addTableColumn(tableColumn)
        }
        tableView.autosaveName = "flaccy.mac.songsTable"
        tableView.autosaveTableColumns = true
        tableView.sortDescriptors = viewModel.sortTiers.map {
            NSSortDescriptor(key: $0.column.rawValue, ascending: $0.ascending)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summaryLabel)

        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),

            scrollView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        viewModel.rowsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rows in
                self?.applyRows(rows)
            }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(
            self, selector: #selector(playbackChanged), name: AudioPlayer.trackDidChange, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func applyRows(_ newRows: [SongsTableViewModel.Row]) {
        rows = newRows
        tableView.reloadData()
        let totalSeconds = newRows.reduce(0.0) { $0 + $1.track.duration }
        summaryLabel.stringValue = PlaybackFormat.songsAndMinutes(count: newRows.count, totalSeconds: totalSeconds)
        let searching = !LibrarySearchState.query.isEmpty
        emptyStateView.isHidden = !newRows.isEmpty
        if newRows.isEmpty {
            if searching {
                emptyStateView.showNoResults(query: LibrarySearchState.query)
            } else {
                emptyStateView.showNoLibrary()
                emptyStateView.isHidden = OnboardingPanelView.visibility != .hide
            }
        }
        AppLogger.debug("Songs table showing \(newRows.count) rows", category: .ui)
    }

    @objc private func playbackChanged() {
        let newPath = AudioPlayer.shared.currentTrack?.fileURL.path
        guard newPath != playingPath else { return }
        playingPath = newPath
        guard let titleIndex = tableView.tableColumns.firstIndex(where: {
            $0.identifier.rawValue == SongsTableViewModel.Column.title.rawValue
        }) else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
            columnIndexes: IndexSet(integer: titleIndex)
        )
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        let tracks = rows.map(\.track)
        AppLogger.info("Playing songs table from row \(row): \(tracks[row].title)", category: .playback)
        AudioPlayer.shared.play(tracks, startingAt: row)
    }

    private func deleteRows(at indexes: IndexSet) {
        let tracks = indexes.compactMap { $0 < rows.count ? rows[$0].track : nil }
        guard !tracks.isEmpty else { return }
        TrackDeletion.confirmAndDelete(tracks, in: view.window)
    }

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard row >= 0, row < rows.count else { return nil }
        if !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return MacTrackMenuFactory.menu(for: rows[row].track, anchor: tableView)
    }

    private func toggleLove(at row: Int) {
        guard row < rows.count else { return }
        let track = rows[row].track
        Task { _ = await LovedTracksService.shared.toggleLove(track: track) }
    }
}

extension SongsTableViewController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isReseedingSort,
              let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let column = SongsTableViewModel.Column(rawValue: key) else { return }
        viewModel.applyPrimarySort(column: column, ascending: descriptor.ascending)
        let seeded = viewModel.sortTiers.map {
            NSSortDescriptor(key: $0.column.rawValue, ascending: $0.ascending)
        }
        if tableView.sortDescriptors != seeded {
            isReseedingSort = true
            tableView.sortDescriptors = seeded
            isReseedingSort = false
        }
        AppLogger.info(
            "Songs sorted by \(viewModel.sortTiers.map { "\($0.column.rawValue)\($0.ascending ? "↑" : "↓")" }.joined(separator: ", "))",
            category: .ui
        )
    }
}

extension SongsTableViewController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row rowIndex: Int) -> NSView? {
        guard rowIndex < rows.count,
              let identifier = tableColumn?.identifier,
              let column = SongsTableViewModel.Column(rawValue: identifier.rawValue) else { return nil }
        let rowData = rows[rowIndex]
        let track = rowData.track

        if column == .loved {
            let cellID = NSUserInterfaceItemIdentifier("lovedCell")
            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? LovedCellView
                ?? LovedCellView(identifier: cellID)
            cell.setLoved(track.loved)
            cell.onToggle = { [weak self] in self?.toggleLove(at: rowIndex) }
            return cell
        }

        if column == .title {
            let cellID = NSUserInterfaceItemIdentifier("titleCell")
            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? PlayingTitleCellView
                ?? PlayingTitleCellView(identifier: cellID)
            cell.configure(
                title: track.title,
                isPlaying: AudioPlayer.shared.currentTrack?.fileURL == track.fileURL
            )
            return cell
        }

        let cellID = NSUserInterfaceItemIdentifier("textCell.\(column.rawValue)")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? TextCellView
            ?? TextCellView(identifier: cellID)
        cell.text = Self.text(for: column, row: rowData)
        cell.isDimmed = column != .artist && column != .album ? true : false
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier.rawValue == SongsTableViewModel.Column.title.rawValue,
              row < rows.count else { return nil }
        return rows[row].track.title
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static func text(for column: SongsTableViewModel.Column, row: SongsTableViewModel.Row) -> String {
        switch column {
        case .title, .loved: ""
        case .artist: row.track.artist
        case .album: row.track.albumTitle
        case .trackNumber: row.track.trackNumber > 0 ? "\(row.track.trackNumber)" : "—"
        case .duration: PlaybackFormat.duration(row.track.duration)
        case .codec: row.track.codec ?? "—"
        case .quality: qualityDetail(row.track)
        case .plays: row.plays > 0 ? "\(row.plays)" : "—"
        case .lastPlayed: row.lastPlayed.map { relativeDateFormatter.localizedString(for: $0, relativeTo: Date()) } ?? "—"
        case .dateAdded: dateFormatter.string(from: row.dateAdded)
        }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static func qualityDetail(_ track: Track) -> String {
        guard let badge = track.qualityBadge else { return "—" }
        guard let codec = track.codec, badge.hasPrefix(codec), badge.count > codec.count else { return badge }
        return String(badge.dropFirst(codec.count + 3))
    }
}

/// Table subclass adding delete-key handling and per-row context menus while
/// letting Space bubble up to the window's play/pause monitor.
final class SongsTableView: NSTableView {

    var onDeleteRows: ((IndexSet) -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, !selectedRowIndexes.isEmpty {
            onDeleteRows?(selectedRowIndexes)
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return super.menu(for: event) }
        return menuProvider?(row) ?? super.menu(for: event)
    }
}

final class TextCellView: NSTableCellView {

    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.toolTip = newValue
        }
    }

    var isDimmed = false {
        didSet { label.textColor = isDimmed ? .secondaryLabelColor : .labelColor }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class PlayingTitleCellView: NSTableCellView {

    private let label = NSTextField(labelWithString: "")
    private let speaker = NSImageView()
    private var speakerWidth: NSLayoutConstraint?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        speaker.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Now playing")
        speaker.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        speaker.contentTintColor = .controlAccentColor
        speaker.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(speaker)
        addSubview(label)
        textField = label

        let width = speaker.widthAnchor.constraint(equalToConstant: 0)
        speakerWidth = width
        NSLayoutConstraint.activate([
            speaker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            speaker.centerYAnchor.constraint(equalTo: centerYAnchor),
            width,
            label.leadingAnchor.constraint(equalTo: speaker.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, isPlaying: Bool) {
        label.stringValue = title
        label.toolTip = title
        label.font = .systemFont(ofSize: 12, weight: isPlaying ? .semibold : .regular)
        speaker.isHidden = !isPlaying
        speakerWidth?.constant = isPlaying ? 14 : 0
    }
}

final class LovedCellView: NSTableCellView {

    var onToggle: (() -> Void)?

    private let button = NSButton()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(toggle)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLoved(_ loved: Bool) {
        button.image = NSImage(
            systemSymbolName: loved ? "heart.fill" : "heart",
            accessibilityDescription: loved ? "Loved" : "Not loved"
        )
        button.contentTintColor = loved
            ? NSColor(red: 1, green: 0.28, blue: 0.42, alpha: 1)
            : .tertiaryLabelColor
    }

    @objc private func toggle() {
        onToggle?()
    }
}
