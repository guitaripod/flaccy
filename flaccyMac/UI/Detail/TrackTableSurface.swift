import AppKit
import FlaccyCore

/// The songs of a page as a sortable table. It never scrolls by itself: it is
/// as tall as its rows and the page scrolls it, so the hero and the table move
/// together in a narrow window. Columns drop out as the pane narrows.
final class TrackTableSurface: NSObject, TrackPageSurface {

    enum Column: String, CaseIterable {
        case number, title, artist, album, disc, plays, quality, time

        var header: String {
            switch self {
            case .number: "#"
            case .title: String(localized: "Title")
            case .artist: String(localized: "Artist")
            case .album: String(localized: "Album")
            case .disc: String(localized: "Disc")
            case .plays: String(localized: "Plays")
            case .quality: String(localized: "Quality")
            case .time: String(localized: "Time")
            }
        }

        var width: CGFloat {
            switch self {
            case .number: 44
            case .title: 160
            case .artist: 200
            case .album: 200
            case .disc: 72
            case .plays: 56
            case .quality: 112
            case .time: 56
            }
        }

        var isTrailing: Bool {
            self == .number || self == .plays || self == .time
        }
    }

    static let rowHeight: CGFloat = 22
    private static let cellSpacing: CGFloat = 8

    private let model: TrackPageModel
    private let host = WidthReportingView()
    private let scroll = PassthroughScrollView()
    private let table = SongsTableView()
    private let height: NSLayoutConstraint
    private var displayed: [Int] = []
    private var sort: (column: Column, ascending: Bool)?
    private var layoutQueued = false

    var onSorted: (() -> Void)?

    var view: NSView { host }

    init(model: TrackPageModel) {
        self.model = model
        height = scroll.heightAnchor.constraint(equalToConstant: 0)
        super.init()

        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: Self.cellSpacing, height: 0)
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.onDeleteRows = { [weak self] rows in self?.removeRows(at: rows) }
        table.menuProvider = { [weak self] row in self?.contextMenu(forRow: row) }
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.header
            tableColumn.width = column.width
            tableColumn.minWidth = 40
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            if column.isTrailing { tableColumn.headerCell.alignment = .right }
            table.addTableColumn(tableColumn)
        }

        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            height,
        ])
        host.onWidthChange = { [weak self] _ in self?.queueColumnLayout() }
    }

    func reload() {
        rebuildDisplayed()
        table.reloadData()
        updateHeight()
        layoutColumns()
    }

    func applyFilter() {
        rebuildDisplayed()
        table.reloadData()
        updateHeight()
    }

    func refreshPlaying() {
        reloadVisibleRows()
    }

    func refreshLoved() {
        reloadVisibleRows()
    }

    func frame(ofEntry index: Int) -> NSRect? {
        guard let row = displayed.firstIndex(of: index) else { return nil }
        host.layoutSubtreeIfNeeded()
        return table.convert(table.rect(ofRow: row), to: host)
    }

    #if DEBUG
    func debugSort(_ column: Column, ascending: Bool) {
        applySort(column, ascending: ascending)
    }
    #endif

    private func reloadVisibleRows() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        table.reloadData(
            forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
            columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)
        )
    }

    private func updateHeight() {
        let header = table.headerView?.frame.height ?? 28
        height.constant = header + CGFloat(displayed.count) * Self.rowHeight
    }

    private func rebuildDisplayed() {
        var indices = model.entries.indices.filter(model.matches)
        if let sort {
            indices.sort { lhs, rhs in
                let order = compare(lhs, rhs, by: sort.column)
                if order == .orderedSame { return lhs < rhs }
                return (order == .orderedAscending) == sort.ascending
            }
        }
        displayed = indices
    }

    private func compare(_ lhs: Int, _ rhs: Int, by column: Column) -> ComparisonResult {
        let a = model.entries[lhs]
        let b = model.entries[rhs]
        switch column {
        case .number: return Self.order(a.number, b.number)
        case .title: return a.track.title.caseInsensitiveCompare(b.track.title)
        case .artist: return a.track.artist.caseInsensitiveCompare(b.track.artist)
        case .album: return a.track.albumTitle.caseInsensitiveCompare(b.track.albumTitle)
        case .disc: return model.discLabel(forEntry: lhs).compare(model.discLabel(forEntry: rhs), options: .numeric)
        case .plays: return Self.order(a.track.playCount, b.track.playCount)
        case .quality: return Self.order(Self.qualityScore(a.track), Self.qualityScore(b.track))
        case .time: return Self.order(a.track.duration, b.track.duration)
        }
    }

    private static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    private static func qualityScore(_ track: Track) -> Int {
        (track.bitDepth ?? 0) * 1_000_000 + (track.sampleRate ?? 0)
    }

    private func applySort(_ column: Column, ascending: Bool) {
        sort = (column, ascending)
        rebuildDisplayed()
        table.reloadData()
        onSorted?()
    }

    private func queueColumnLayout() {
        guard !layoutQueued else { return }
        layoutQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            layoutQueued = false
            layoutColumns()
        }
    }

    /// Hides the columns the pane has no room for and gives the rest of its
    /// width to the title.
    private func layoutColumns() {
        let width = host.bounds.width
        guard width > 0 else { return }
        var visible: Set<Column> = [.number, .title, .time]
        if model.artistsVary && width >= 480 { visible.insert(.artist) }
        if model.kind == .playlist && width >= 760 { visible.insert(.album) }
        if model.sections != nil && width >= 420 { visible.insert(.disc) }
        if width >= 640 { visible.insert(.quality) }
        if width >= 560 { visible.insert(.plays) }
        var others: CGFloat = 0
        for column in Column.allCases {
            guard let tableColumn = table.tableColumn(withIdentifier: .init(column.rawValue)) else { continue }
            if tableColumn.isHidden == visible.contains(column) { tableColumn.isHidden = !visible.contains(column) }
            if column != .title && visible.contains(column) { others += column.width }
        }
        let spacing = Self.cellSpacing * CGFloat(visible.count)
        table.tableColumn(withIdentifier: .init(Column.title.rawValue))?.width = max(
            Column.title.width, width - others - spacing
        )
    }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard displayed.indices.contains(row) else { return }
        let tracks = displayed.map { model.entries[$0].track }
        AppLogger.info("Playing \(tracks[row].title) from \(model.pageName()) table", category: .playback)
        model.play(tracks, row)
    }

    private func removeRows(at rows: IndexSet) {
        let victims = rows.compactMap { displayed.indices.contains($0) ? model.entries[displayed[$0]] : nil }
        guard !victims.isEmpty else { return }
        model.remove?(victims)
    }

    private func contextMenu(forRow row: Int) -> NSMenu? {
        guard displayed.indices.contains(row) else { return nil }
        if !table.selectedRowIndexes.contains(row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return model.menu(model.entries[displayed[row]], table)
    }
}

extension TrackTableSurface: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayed.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let column = Column(rawValue: key) else { return }
        applySort(column, ascending: descriptor.ascending)
    }
}

extension TrackTableSurface: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayed.indices.contains(row),
              let identifier = tableColumn?.identifier,
              let column = Column(rawValue: identifier.rawValue) else { return nil }
        let entry = model.entries[displayed[row]]
        let cellID = NSUserInterfaceItemIdentifier("trackCell.\(column.rawValue)")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? TrackTableCell
            ?? TrackTableCell(identifier: cellID, column: column)
        let track = entry.track
        let isPlaying = AudioPlayer.shared.currentTrack?.fileURL == track.fileURL
        let text: String
        switch column {
        case .number: text = "\(entry.number)"
        case .title: text = track.title
        case .artist: text = track.artist
        case .album: text = track.albumTitle
        case .disc: text = model.discLabel(forEntry: displayed[row])
        case .plays: text = track.playCount > 0 ? "\(track.playCount)" : ""
        case .quality: text = track.qualityBadge ?? ""
        case .time: text = PlaybackFormat.duration(track.duration)
        }
        cell.configure(
            text: text,
            isPlaying: isPlaying,
            animatesBars: AudioPlayer.shared.isPlaying,
            loved: column == .title && LovedTracksService.shared.isLoved(track: track)
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier.rawValue == Column.title.rawValue, displayed.indices.contains(row) else { return nil }
        return model.entries[displayed[row]].track.title
    }
}

/// One cell of the track table. The number column swaps its digits for the
/// equalizer bars on the playing row, the title column carries the loved heart
/// and the playing row's text takes the accent colour in every column.
final class TrackTableCell: NSTableCellView {

    private let label = NSTextField(labelWithString: "")
    private let bars = PlayingBarsView()
    private let heart = NSImageView()
    private let column: TrackTableSurface.Column
    private var isPlaying = false

    init(identifier: NSUserInterfaceItemIdentifier, column: TrackTableSurface.Column) {
        self.column = column
        super.init(frame: .zero)
        self.identifier = identifier

        label.font = column.isTrailing
            ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = column.isTrailing ? .right : .left
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label

        heart.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: String(localized: "Loved"))
        heart.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        heart.contentTintColor = Self.loveInk
        heart.isHidden = true
        heart.translatesAutoresizingMaskIntoConstraints = false

        bars.isHidden = true
        bars.tint = .controlAccentColor
        bars.translatesAutoresizingMaskIntoConstraints = false

        var constraints = [label.centerYAnchor.constraint(equalTo: centerYAnchor)]
        switch column {
        case .number:
            addSubview(bars)
            constraints += [
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                bars.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                bars.centerYAnchor.constraint(equalTo: centerYAnchor),
                bars.widthAnchor.constraint(equalToConstant: 14),
                bars.heightAnchor.constraint(equalToConstant: 12),
            ]
        case .title:
            addSubview(heart)
            constraints += [
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(lessThanOrEqualTo: heart.leadingAnchor, constant: -4),
                heart.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                heart.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        default:
            constraints += [
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    func configure(text: String, isPlaying: Bool, animatesBars: Bool, loved: Bool) {
        label.stringValue = text
        label.toolTip = column == .number ? nil : text
        self.isPlaying = isPlaying
        let weight: NSFont.Weight = isPlaying && column == .title ? .semibold : .regular
        label.font = column.isTrailing
            ? .monospacedDigitSystemFont(ofSize: 12, weight: weight)
            : .systemFont(ofSize: 12, weight: weight)
        if column == .number {
            label.isHidden = isPlaying
            bars.isHidden = !isPlaying
            bars.setPlaying(isPlaying && animatesBars)
        }
        applyColors()
        heart.isHidden = !loved
    }

    private func applyColors() {
        let emphasized = backgroundStyle == .emphasized
        let dimmed = column != .title && column != .artist && column != .album
        let playingInk: NSColor = emphasized ? .alternateSelectedControlTextColor : .controlAccentColor
        label.textColor = isPlaying ? playingInk : (dimmed ? .secondaryLabelColor : .labelColor)
        bars.tint = playingInk
        heart.contentTintColor = emphasized ? .alternateSelectedControlTextColor : Self.loveInk
    }

    private static let loveInk = NSColor(red: 1, green: 0.28, blue: 0.42, alpha: 1)
}
