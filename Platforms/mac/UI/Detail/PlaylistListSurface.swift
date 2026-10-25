import AppKit
import MidgarCore

/// A playlist's songs as rows the listener can drag into a new order. It is a
/// table underneath, as tall as its rows and without a scroller of its own, so
/// the page scrolls it, and it keeps the native multi-row drag, selection and
/// delete key. Reordering stands down while a filter hides rows, because a
/// drop position among some of the rows means nothing for the rest.
final class PlaylistListSurface: NSObject, TrackPageSurface {

    private static let dragType = NSPasteboard.PasteboardType("com.midgarcorp.flaccy.playlistRow")
    private static let rowHeight: CGFloat = 40

    private let model: TrackPageModel
    private let host = NSView()
    private let scroll = PassthroughScrollView()
    private let table = SongsTableView()
    private let height: NSLayoutConstraint
    private var displayed: [Int] = []

    var view: NSView { host }

    init(model: TrackPageModel) {
        self.model = model
        height = scroll.heightAnchor.constraint(equalToConstant: 0)
        super.init()

        table.style = .plain
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.registerForDraggedTypes([Self.dragType])
        table.onDeleteRows = { [weak self] rows in self?.removeRows(at: rows) }
        table.menuProvider = { [weak self] row in self?.contextMenu(forRow: row) }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.sizeLastColumnToFit()

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
    }

    func reload() {
        displayed = model.entries.indices.filter(model.matches)
        table.reloadData()
        height.constant = CGFloat(displayed.count) * Self.rowHeight
    }

    func applyFilter() {
        reload()
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

    private func reloadVisibleRows() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        table.reloadData(
            forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard displayed.indices.contains(row) else { return }
        let tracks = model.entries.map(\.track)
        MidgarLog.info("Playing \(tracks[displayed[row]].title) from \(model.pageName())", category: .playback)
        model.play(tracks, displayed[row])
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

extension PlaylistListSurface: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayed.count
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard model.query.isEmpty else { return nil }
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
        guard model.query.isEmpty, dropOperation == .above else { return [] }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard model.query.isEmpty, let items = info.draggingPasteboard.pasteboardItems else { return false }
        let sources = items
            .compactMap { $0.string(forType: Self.dragType) }
            .compactMap(Int.init)
        guard !sources.isEmpty else { return false }
        model.reorder?(IndexSet(sources), row)
        return true
    }
}

extension PlaylistListSurface: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayed.indices.contains(row) else { return nil }
        let entry = model.entries[displayed[row]]
        let cellID = NSUserInterfaceItemIdentifier("playlistRow")
        let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? PlaylistRowCell
            ?? PlaylistRowCell(identifier: cellID)
        cell.row.configure(
            number: entry.number,
            title: entry.track.title,
            duration: entry.track.duration,
            loved: LovedTracksService.shared.isLoved(track: entry.track),
            isPlaying: AudioPlayer.shared.currentTrack?.fileURL == entry.track.fileURL,
            subtitle: entry.track.artist,
            newMix: entry.track.showsNewMix
        )
        cell.row.onToggleLove = {
            Task { _ = await LovedTracksService.shared.toggleLove(track: entry.track) }
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        displayed.indices.contains(row) ? model.entries[displayed[row]].track.title : nil
    }
}

/// A playlist row: the album page's song row inside a table cell.
final class PlaylistRowCell: NSTableCellView {

    let row = DetailTrackRowView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
