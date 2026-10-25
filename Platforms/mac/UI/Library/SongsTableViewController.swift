import AppKit
import MidgarCore
import Combine

extension Notification.Name {
    static let flaccyJumpToCurrentSong = Notification.Name("flaccy.mac.jumpToCurrentSong")
}

/// Multi-column sortable songs table: filter chips with a ranged Most Played,
/// click-to-sort headers, type-select, double-click plays the visible order as
/// the queue context, delete-key removal, per-row loved hearts, the canonical
/// track context menu and a status line that totals what is on screen.
final class SongsTableViewController: NSViewController {

    private let viewModel = SongsTableViewModel()
    private let scrollView = NSScrollView()
    private let tableView = SongsTableView()
    private let emptyStateView = LibraryEmptyStateView()
    private let chipsBar = FilterChipsBar()
    private let playButton = GlassCapsuleButton(title: String(localized: "Play"), symbolName: "play.fill", prominent: true)
    private let shuffleButton = GlassCapsuleButton(title: String(localized: "Shuffle"), symbolName: "shuffle")
    private let saveButton = GlassCapsuleButton(title: String(localized: "Save as Playlist…"), symbolName: "text.badge.plus", iconOnly: true)
    private let statusLabel = NSTextField(labelWithString: "")
    private var cancellables = Set<AnyCancellable>()
    private var rows: [SongsTableViewModel.Row] = []
    private var playingPath: String?
    private var isReseedingSort = false
    private var pendingReveal: (path: String, clearedSearch: Bool)?

    private static let playsHeaderMinimumWidth: CGFloat = 84

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

        let controls = buildControlsBar()
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        view.addSubview(emptyStateView)

        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            controls.heightAnchor.constraint(equalToConstant: 32),

            scrollView.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),

            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    /// Chips fill the leading edge and scroll when the window is narrow; the
    /// three actions keep their width at the trailing edge.
    private func buildControlsBar() -> NSView {
        chipsBar.configure(chips: viewModel.chips, selected: viewModel.filter.rawValue)
        chipsBar.onSelectChip = { [weak self] id in
            guard let filter = SongsTableViewModel.Filter(rawValue: id) else { return }
            self?.choose(filter)
        }
        chipsBar.menuProvider = { [weak self] id in
            id == SongsTableViewModel.Filter.mostPlayed.rawValue ? self?.rangeMenu() : nil
        }
        chipsBar.setContentHuggingPriority(.init(1), for: .horizontal)
        chipsBar.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        playButton.onClick = { [weak self] in self?.playVisible(shuffled: false) }
        shuffleButton.onClick = { [weak self] in self?.playVisible(shuffled: true) }
        saveButton.onClick = { [weak self] in self?.saveVisibleAsPlaylist() }

        let actions = MacLiquidGlass.buttonGroup([playButton, shuffleButton, saveButton])
        let bar = NSStackView(views: [chipsBar, actions])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.alignment = .centerY
        return bar
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(jumpToCurrentSong), name: .flaccyJumpToCurrentSong, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func applyRows(_ newRows: [SongsTableViewModel.Row]) {
        rows = newRows
        tableView.reloadData()
        refreshPlaysHeader()
        refreshActions()
        refreshStatusLine()
        let searching = !LibrarySearchState.query.isEmpty
        emptyStateView.isHidden = !newRows.isEmpty
        if newRows.isEmpty {
            if searching {
                emptyStateView.showNoResults(query: LibrarySearchState.query)
            } else if viewModel.hasLibrary {
                emptyStateView.showNoMatches(for: viewModel.filter == .mostPlayed ? viewModel.mostPlayedTitle : viewModel.filter.title)
            } else {
                emptyStateView.showNoLibrary()
                emptyStateView.isHidden = OnboardingPanelView.visibility != .hide
            }
        }
        MidgarLog.debug("Songs table showing \(newRows.count) rows", category: .ui)
        resolvePendingReveal()
    }

    private func refreshActions() {
        let hasRows = !rows.isEmpty
        [playButton, shuffleButton, saveButton].forEach { $0.isEnabled = hasRows }
    }

    /// Names the Plays column for the range its counts cover, and makes sure
    /// the header has the width to say so, since a saved column width predates
    /// the longer title.
    private func refreshPlaysHeader() {
        guard let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(SongsTableViewModel.Column.plays.rawValue)) else { return }
        column.title = viewModel.playsColumnTitle
        if viewModel.displayedPlaysRange != nil, column.width < Self.playsHeaderMinimumWidth {
            column.width = Self.playsHeaderMinimumWidth
        }
    }

    private func refreshStatusLine() {
        let selected = tableView.selectedRowIndexes.filter { $0 < rows.count }
        if selected.isEmpty {
            statusLabel.stringValue = SongsStatusFormat.summary(count: rows.count, seconds: Self.totalSeconds(rows))
        } else {
            statusLabel.stringValue = SongsStatusFormat.selection(
                count: selected.count, seconds: Self.totalSeconds(selected.map { rows[$0] })
            )
        }
    }

    private static func totalSeconds(_ rows: [SongsTableViewModel.Row]) -> TimeInterval {
        rows.reduce(0) { $0 + $1.track.duration }
    }

    private func choose(_ filter: SongsTableViewModel.Filter) {
        viewModel.select(filter)
        syncChipsAndSort()
    }

    private func chooseMostPlayed(range: ChartPeriod) {
        viewModel.selectMostPlayed(range: range)
        syncChipsAndSort()
    }

    private func syncChipsAndSort() {
        chipsBar.update(chips: viewModel.chips)
        chipsBar.setSelected(id: viewModel.filter.rawValue)
        reseedSortDescriptors()
        if tableView.numberOfRows > 0 {
            tableView.scrollRowToVisible(0)
        }
    }

    private func reseedSortDescriptors() {
        let seeded = viewModel.sortTiers.map {
            NSSortDescriptor(key: $0.column.rawValue, ascending: $0.ascending)
        }
        guard tableView.sortDescriptors != seeded else { return }
        isReseedingSort = true
        tableView.sortDescriptors = seeded
        isReseedingSort = false
    }

    private func rangeMenu() -> NSMenu {
        let menu = NSMenu()
        for period in ChartPeriod.allCases {
            let item = ClosureMenuItem(title: period.displayName) { [weak self] in
                self?.chooseMostPlayed(range: period)
            }
            item.state = period == viewModel.mostPlayedRange ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func playVisible(shuffled: Bool) {
        let tracks = rows.map(\.track)
        guard !tracks.isEmpty else { return }
        MidgarLog.info("Playing songs list: \(tracks.count) tracks, shuffled: \(shuffled)", category: .playback)
        AudioPlayer.shared.play(shuffled ? tracks.shuffled() : tracks, startingAt: 0)
    }

    private func saveVisibleAsPlaylist() {
        let tracks = rows.map(\.track)
        guard !tracks.isEmpty else { return }
        let name = viewModel.filter == .mostPlayed ? viewModel.mostPlayedTitle : viewModel.filter.title
        PlaylistActions.promptForNewPlaylist(adding: tracks, suggestedName: name, in: view.window)
    }

    #if DEBUG
    var visibleTrackPathsForExercise: [String] { rows.map(\.id) }

    var selectedTrackPathForExercise: String? {
        tableView.selectedRow >= 0 && tableView.selectedRow < rows.count ? rows[tableView.selectedRow].id : nil
    }

    var filterForExercise: SongsTableViewModel.Filter { viewModel.filter }

    var statusLineForExercise: String { statusLabel.stringValue }

    func selectFilterForCapture(_ filter: SongsTableViewModel.Filter, range: ChartPeriod?) {
        if let range {
            chooseMostPlayed(range: range)
        } else {
            choose(filter)
        }
    }
    #endif

    @objc private func jumpToCurrentSong() {
        guard let path = AudioPlayer.shared.currentTrack?.fileURL.path else {
            MidgarLog.info("Jump to current song: nothing is playing", category: .ui)
            return
        }
        pendingReveal = (path, false)
        resolvePendingReveal()
    }

    /// Selects the playing song's row, first widening what the table shows if
    /// that row is hidden: back to the All chip, then, only if the search box
    /// is what still hides it, with the search cleared. Each step republishes
    /// the rows, which land here again.
    private func resolvePendingReveal() {
        guard let pending = pendingReveal else { return }
        if let index = rows.firstIndex(where: { $0.id == pending.path }) {
            pendingReveal = nil
            reveal(row: index)
        } else if viewModel.filter != .all {
            choose(.all)
        } else if !LibrarySearchState.query.isEmpty, !pending.clearedSearch {
            pendingReveal = (pending.path, true)
            LibrarySearchState.requestClear()
        } else {
            pendingReveal = nil
            MidgarLog.info("Jump to current song: the playing track is not in the songs list", category: .ui)
        }
    }

    private func reveal(row index: Int) {
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        let target = tableView.rect(ofRow: index)
        let clip = scrollView.contentView
        let maximum = max(0, tableView.bounds.height - clip.bounds.height)
        let offset = min(max(0, target.midY - clip.bounds.height / 2), maximum)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: offset))
        scrollView.reflectScrolledClipView(clip)
        view.window?.makeFirstResponder(tableView)
        MidgarLog.info("Jump to current song: row \(index)", category: .ui)
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
        MidgarLog.info("Playing songs table from row \(row): \(tracks[row].title)", category: .playback)
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
        if tableView.numberOfRows > 0 {
            tableView.scrollRowToVisible(0)
        }
        MidgarLog.info(
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
                isPlaying: AudioPlayer.shared.currentTrack?.fileURL == track.fileURL,
                newMix: track.showsNewMix
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshStatusLine()
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
    private let newMixChip = MacNewMixChip()
    private var speakerWidth: NSLayoutConstraint?
    private var chipConstraints: [NSLayoutConstraint] = []
    private var plainTitleConstraints: [NSLayoutConstraint] = []

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        speaker.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: String(localized: "Now playing"))
        speaker.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        speaker.contentTintColor = .controlAccentColor
        speaker.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        newMixChip.isHidden = true
        newMixChip.translatesAutoresizingMaskIntoConstraints = false

        addSubview(speaker)
        addSubview(label)
        addSubview(newMixChip)
        textField = label

        let width = speaker.widthAnchor.constraint(equalToConstant: 0)
        speakerWidth = width
        plainTitleConstraints = [label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2)]
        chipConstraints = [
            newMixChip.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            newMixChip.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            newMixChip.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        NSLayoutConstraint.activate(plainTitleConstraints + [
            speaker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            speaker.centerYAnchor.constraint(equalTo: centerYAnchor),
            width,
            label.leadingAnchor.constraint(equalTo: speaker.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTint() }
    }

    func configure(title: String, isPlaying: Bool, newMix: Bool = false) {
        label.stringValue = title
        label.toolTip = title
        label.setAccessibilityLabel(TrackVersionCopy.accessibilityLabel(title, newMix: newMix))
        showNewMixChip(newMix)
        label.font = .systemFont(ofSize: 12, weight: isPlaying ? .semibold : .regular)
        speaker.isHidden = !isPlaying
        speakerWidth?.constant = isPlaying ? 14 : 0
        applyTint()
    }

    /// Puts the chip right after the title, or hands the title the whole room
    /// again when the song has no new mix.
    private func showNewMixChip(_ shows: Bool) {
        guard newMixChip.isHidden == shows else { return }
        newMixChip.isHidden = !shows
        if shows {
            NSLayoutConstraint.deactivate(plainTitleConstraints)
            NSLayoutConstraint.activate(chipConstraints)
        } else {
            NSLayoutConstraint.deactivate(chipConstraints)
            NSLayoutConstraint.activate(plainTitleConstraints)
        }
    }

    private func applyTint() {
        let emphasized = backgroundStyle == .emphasized
        speaker.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .controlAccentColor
        label.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
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
            accessibilityDescription: loved ? String(localized: "Loved") : String(localized: "Not loved")
        )
        button.contentTintColor = loved
            ? NSColor(red: 1, green: 0.28, blue: 0.42, alpha: 1)
            : .tertiaryLabelColor
    }

    @objc private func toggle() {
        onToggle?()
    }
}
