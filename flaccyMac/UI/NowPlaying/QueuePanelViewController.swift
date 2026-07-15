import AppKit
import UniformTypeIdentifiers

/// The queue panel used both as the window inspector and inside the immersive
/// Now Playing view: History (dimmed, click jumps back), the highlighted
/// Now Playing card with animated bars, and a drag-reorderable Up Next group
/// with a clear button and time-remaining summary.
final class QueuePanelViewController: NSViewController {

    private enum Row {
        case header(String)
        case upNextHeader
        case track(index: Int, group: QueueRowGroup)
    }

    private let player: AudioPlaying = AudioPlayer.shared
    private var rows: [Row] = []
    private var isActive = true
    private var needsReload = false
    private let tableView = QueueTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Nothing queued — play an album to fill Up Next.")
    private static let dragType = NSPasteboard.PasteboardType("com.midgarcorp.flaccy.mac.queue-row")

    override func loadView() {
        view = NSView()

        tableView.style = .plain
        tableView.headerView = nil
        tableView.rowHeight = 52
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.registerForDraggedTypes([Self.dragType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self
        tableView.onDeleteRow = { [weak self] row in
            self?.deleteRow(row)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("queue"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(queueChanged), name: AudioPlayer.queueDidChange, object: nil)
        center.addObserver(self, selector: #selector(queueChanged), name: AudioPlayer.trackDidChange, object: nil)
        center.addObserver(self, selector: #selector(playbackStateChanged), name: AudioPlayer.playbackStateDidChange, object: nil)
        reload()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Called by the immersive Now Playing view when this panel's column shows or
    /// hides, so a hidden queue column stops rebuilding its table. Defaults to
    /// active for the always-on window inspector.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active, needsReload {
            needsReload = false
            reload()
        }
    }

    @objc private func queueChanged() {
        reload()
    }

    @objc private func playbackStateChanged() {
        guard let currentRow = rows.firstIndex(where: {
            if case .track(_, .current) = $0 { return true } else { return false }
        }) else { return }
        if let cell = tableView.view(atColumn: 0, row: currentRow, makeIfNecessary: false) as? QueueTrackCellView {
            cell.setPlaying(player.isPlaying)
        }
    }

    private func reload() {
        guard isActive else {
            needsReload = true
            return
        }
        rows = Self.buildRows(queue: player.queue, currentIndex: player.currentIndex)
        emptyLabel.isHidden = !player.queue.isEmpty
        tableView.reloadData()
        scrollToCurrent()
        AppLogger.debug("Queue panel reload: \(rows.count) rows, table frame \(tableView.frame)", category: .ui)
    }

    private static func buildRows(queue: [Track], currentIndex: Int) -> [Row] {
        guard !queue.isEmpty else { return [] }
        var rows: [Row] = []
        if currentIndex > 0 {
            rows.append(.header("History"))
            for index in 0..<currentIndex {
                rows.append(.track(index: index, group: .history))
            }
        }
        if currentIndex < queue.count {
            rows.append(.header("Now Playing"))
            rows.append(.track(index: currentIndex, group: .current))
        }
        if currentIndex + 1 < queue.count {
            rows.append(.upNextHeader)
            for index in (currentIndex + 1)..<queue.count {
                rows.append(.track(index: index, group: .upNext))
            }
        }
        return rows
    }

    private func scrollToCurrent() {
        guard let currentRow = rows.firstIndex(where: {
            if case .track(_, .current) = $0 { return true } else { return false }
        }) else { return }
        tableView.scrollRowToVisible(currentRow)
    }

    private func upNextSummary() -> String {
        let upcoming = player.queue.dropFirst(player.currentIndex + 1)
        guard !upcoming.isEmpty else { return "" }
        let seconds = upcoming.reduce(0.0) { $0 + $1.duration }
        let minutes = Int(seconds / 60)
        let time = minutes >= 60
            ? String(format: "%dh %02dm", minutes / 60, minutes % 60)
            : "\(minutes) min"
        return "\(upcoming.count) track\(upcoming.count == 1 ? "" : "s") · \(time)"
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count, case .track(let index, let group) = rows[row] else { return }
        guard group != .current else { return }
        player.jumpToIndex(index)
        AppLogger.info("Queue panel jump to index \(index)", category: .ui)
    }

    @objc private func clearUpNext() {
        player.clearUpNext()
    }

    private func deleteRow(_ row: Int) {
        guard row >= 0, row < rows.count, case .track(let index, .upNext) = rows[row] else { return }
        player.removeFromQueue(at: index)
    }

    private func track(atRow row: Int) -> (track: Track, index: Int)? {
        guard row >= 0, row < rows.count, case .track(let index, _) = rows[row],
              index < player.queue.count else { return nil }
        return (player.queue[index], index)
    }
}

extension QueuePanelViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: 30
        case .upNextHeader: 46
        case .track(_, .current): 60
        case .track: 52
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = tableView.reusableView(id: "header") { QueueHeaderCellView() }
            cell.configure(title: title, summary: nil, showsClear: false, target: nil, action: nil)
            return cell
        case .upNextHeader:
            let cell = tableView.reusableView(id: "header") { QueueHeaderCellView() }
            cell.configure(
                title: "Up Next", summary: upNextSummary(), showsClear: true,
                target: self, action: #selector(clearUpNext)
            )
            return cell
        case .track(let index, let group):
            guard index < player.queue.count else { return nil }
            let cell = tableView.reusableView(id: "track") { QueueTrackCellView() }
            cell.configure(track: player.queue[index], group: group)
            if group == .current { cell.setPlaying(player.isPlaying) }
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard case .track(let index, .upNext) = rows[row] else { return nil }
        let item = NSPasteboardItem()
        item.setString("\(index)", forType: Self.dragType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
        proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard dropOperation == .above, queueIndex(forDropRow: row) != nil else { return [] }
        return .move
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
        row: Int, dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let sourceString = info.draggingPasteboard.string(forType: Self.dragType),
              let sourceIndex = Int(sourceString),
              var destination = queueIndex(forDropRow: row) else { return false }
        if destination > sourceIndex { destination -= 1 }
        guard destination != sourceIndex else { return false }
        player.moveInQueue(from: sourceIndex, to: destination)
        AppLogger.info("Queue panel reorder \(sourceIndex) -> \(destination)", category: .ui)
        return true
    }

    /// Maps a drop gap (row boundary) to the queue index a dragged track would
    /// occupy, allowing drops only within the Up Next group (including its end).
    private func queueIndex(forDropRow row: Int) -> Int? {
        let firstUpNext = player.currentIndex + 1
        guard firstUpNext < player.queue.count else { return nil }
        if row >= rows.count {
            return player.queue.count
        }
        switch rows[row] {
        case .track(let index, .upNext):
            return index
        default:
            if row > 0, case .track(let previous, .upNext) = rows[row - 1] {
                return previous + 1
            }
            return nil
        }
    }
}

extension QueuePanelViewController: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let (track, index) = track(atRow: tableView.clickedRow) else { return }

        if let badge = track.qualityBadge {
            let info = menu.addItem(withTitle: badge, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(.separator())
        }
        if index != player.currentIndex {
            let remove = menu.addItem(withTitle: "Remove from Queue", action: #selector(menuRemove(_:)), keyEquivalent: "")
            remove.target = self
            remove.tag = index
        }
        let loved = LovedTracksService.shared.isLoved(track: track)
        let love = menu.addItem(
            withTitle: loved ? "Unlove" : "Love", action: #selector(menuLove(_:)), keyEquivalent: ""
        )
        love.target = self
        love.tag = index
        let goToAlbum = menu.addItem(withTitle: "Go to Album", action: #selector(menuGoToAlbum(_:)), keyEquivalent: "")
        goToAlbum.target = self
        goToAlbum.tag = index
    }

    @objc private func menuRemove(_ sender: NSMenuItem) {
        player.removeFromQueue(at: sender.tag)
    }

    @objc private func menuLove(_ sender: NSMenuItem) {
        guard sender.tag < player.queue.count else { return }
        let track = player.queue[sender.tag]
        Task { _ = await LovedTracksService.shared.toggleLove(track: track) }
    }

    @objc private func menuGoToAlbum(_ sender: NSMenuItem) {
        guard sender.tag < player.queue.count else { return }
        let track = player.queue[sender.tag]
        LibraryNavigator.revealAlbum(title: track.albumTitle, artist: track.artist)
    }
}

enum QueueRowGroup {
    case history
    case current
    case upNext
}

/// Table that forwards the delete key to a closure so Up Next rows can be
/// removed from the keyboard.
final class QueueTableView: NSTableView {

    var onDeleteRow: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == String(UnicodeScalar(NSDeleteCharacter)!) ||
            event.specialKey == .deleteForward {
            let row = selectedRow >= 0 ? selectedRow : clickedRow
            if row >= 0 {
                onDeleteRow?(row)
                return
            }
        }
        super.keyDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
}

extension NSTableView {
    func reusableView<T: NSView>(id: String, make: () -> T) -> T {
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let view = makeView(withIdentifier: identifier, owner: nil) as? T {
            return view
        }
        let view = make()
        view.identifier = identifier
        return view
    }
}

final class QueueHeaderCellView: NSView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = .secondaryLabelColor
        summaryLabel.font = .systemFont(ofSize: 10)
        summaryLabel.textColor = .tertiaryLabelColor
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.controlSize = .small
        clearButton.font = .systemFont(ofSize: 11, weight: .medium)

        let textColumn = NSStackView(views: [titleLabel, summaryLabel])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 1

        let row = NSStackView(views: [textColumn, NSView(), clearButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 2, right: 12)
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

    func configure(title: String, summary: String?, showsClear: Bool, target: AnyObject?, action: Selector?) {
        titleLabel.stringValue = title.uppercased()
        summaryLabel.stringValue = summary ?? ""
        summaryLabel.isHidden = (summary ?? "").isEmpty
        clearButton.isHidden = !showsClear
        clearButton.target = target
        clearButton.action = action
    }
}

final class QueueTrackCellView: NSView {

    private let artworkView = NSImageView()
    private let artworkContainer = NSView()
    private let placeholder = CAGradientLayer()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let bars = PlayingBarsView()
    private let card = NSView()
    private var artworkKey: String?

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        artworkContainer.wantsLayer = true
        artworkContainer.layer?.cornerRadius = 6
        artworkContainer.layer?.masksToBounds = true
        artworkContainer.layer?.addSublayer(placeholder)
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.addSubview(artworkView)
        artworkContainer.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [titleLabel, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        bars.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [artworkContainer, text, NSView(), bars])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            row.topAnchor.constraint(equalTo: card.topAnchor),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            artworkContainer.widthAnchor.constraint(equalToConstant: 36),
            artworkContainer.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholder.frame = artworkContainer.bounds
        CATransaction.commit()
    }

    func configure(track: Track, group: QueueRowGroup) {
        titleLabel.stringValue = track.title
        subtitleLabel.stringValue = track.artist
        toolTip = "\(track.title) — \(track.artist)"

        let isCurrent = group == .current
        let isHistory = group == .history
        alphaValue = isHistory ? 0.45 : 1
        card.layer?.backgroundColor = isCurrent
            ? NSColor.labelColor.withAlphaComponent(0.1).cgColor
            : NSColor.clear.cgColor
        bars.isHidden = !isCurrent
        titleLabel.font = .systemFont(ofSize: 12, weight: isCurrent ? .semibold : .medium)
        bars.tint = NSColor(red: 0.45, green: 0.86, blue: 0.92, alpha: 1)

        let key = "\(track.albumTitle)\u{0}\(track.artist)"
        artworkKey = key
        if let cached = track.artwork
            ?? AlbumArtworkCache.shared.thumbnail(forAlbum: track.albumTitle, artist: track.artist) {
            artworkView.image = cached
            placeholder.isHidden = true
        } else {
            showPlaceholder(seed: "\(track.albumTitle)|\(track.artist)")
            AlbumArtworkCache.shared.loadThumbnail(forAlbum: track.albumTitle, artist: track.artist) { [weak self] image in
                guard let self, self.artworkKey == key, let image else { return }
                self.artworkView.image = image
                self.placeholder.isHidden = true
            }
        }
    }

    func setPlaying(_ playing: Bool) {
        bars.setPlaying(playing)
    }

    private func showPlaceholder(seed: String) {
        artworkView.image = nil
        placeholder.isHidden = false
        let (base, second) = PlaceholderGradient.colors(seed: seed)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholder.colors = [base.cgColor, second.cgColor]
        placeholder.startPoint = CGPoint(x: 0, y: 1)
        placeholder.endPoint = CGPoint(x: 1, y: 0)
        placeholder.frame = artworkContainer.bounds
        CATransaction.commit()
    }
}
