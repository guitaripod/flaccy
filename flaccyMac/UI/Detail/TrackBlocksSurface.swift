import AppKit
import MidgarCore
import FlaccyCore

/// An album's songs as rows grouped under their disc headers. With `columns`
/// off the blocks run down the page; with it on they are boxed and flowed side
/// by side over as many columns as the width has room for, split by
/// `TrackPageLayout` so the heights come out even.
final class TrackBlocksSurface: TrackPageSurface {

    private struct Block {
        let range: Range<Int>
        let header: NSView?
        let container: NSView
    }

    private let model: TrackPageModel
    private let columns: Bool
    private let host = WidthReportingView()
    private var root: NSStackView?
    private var blocks: [Block] = []
    private var rows: [DetailTrackRowView?] = []
    private var columnCount = 0
    private var rebuildQueued = false

    var view: NSView { host }

    init(model: TrackPageModel, columns: Bool) {
        self.model = model
        self.columns = columns
        host.onWidthChange = { [weak self] _ in self?.widthChanged() }
    }

    func reload() {
        rebuild()
    }

    func applyFilter() {
        for (index, row) in rows.enumerated() {
            row?.isHidden = !model.matches(index)
        }
        for block in blocks {
            let visible = block.range.contains(where: model.matches)
            block.header?.isHidden = !visible
            block.container.isHidden = !visible
        }
    }

    func refreshPlaying() {
        let playing = AudioPlayer.shared.currentTrack?.fileURL
        for (index, row) in rows.enumerated() {
            row?.setPlaying(model.entries[index].track.fileURL == playing)
        }
    }

    func refreshLoved() {
        for (index, row) in rows.enumerated() {
            row?.setLoved(LovedTracksService.shared.isLoved(track: model.entries[index].track))
        }
    }

    func frame(ofEntry index: Int) -> NSRect? {
        guard rows.indices.contains(index), let row = rows[index], !row.isHidden else { return nil }
        host.layoutSubtreeIfNeeded()
        return row.convert(row.bounds, to: host)
    }

    private var blockCount: Int {
        model.sections?.count ?? max(model.entries.count / TrackPageLayout.songsPerColumn, 1)
    }

    private func widthChanged() {
        guard columns, !rebuildQueued else { return }
        rebuildQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            rebuildQueued = false
            let wanted = TrackPageLayout.columnCount(width: Int(host.bounds.width), blocks: blockCount)
            if root == nil || wanted != columnCount { rebuild() }
        }
    }

    /// The runs of songs each column holds: whole discs balanced over the
    /// columns, or equal runs of an album that has none.
    private func plan(columns count: Int) -> [[(range: Range<Int>, section: TrackPageSection?)]] {
        if let sections = model.sections {
            let sizes = sections.map { $0.range.count }
            return TrackPageLayout.balanceColumns(sizes: sizes, columns: count).map { sectionRange in
                sections[sectionRange].map { (range: $0.range, section: $0) }
            }
        }
        return TrackPageLayout.evenRuns(count: model.entries.count, columns: count).map {
            [(range: $0, section: nil)]
        }
    }

    /// Builds the blocks. Columns wait for the width they will be flowed over,
    /// which arrives right after the surface is shown, so the rows are not
    /// built twice.
    private func rebuild() {
        root?.removeFromSuperview()
        root = nil
        blocks = []
        rows = Array(repeating: nil, count: model.entries.count)
        if columns && host.bounds.width == 0 { return }
        columnCount = columns
            ? TrackPageLayout.columnCount(width: Int(host.bounds.width), blocks: blockCount)
            : 1

        let columnViews = plan(columns: columnCount).map { column -> NSStackView in
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
            for planned in column {
                let block = makeBlock(range: planned.range, section: planned.section)
                blocks.append(block)
                if let header = block.header {
                    stack.addArrangedSubview(header)
                    header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                    stack.setCustomSpacing(2, after: header)
                }
                stack.addArrangedSubview(block.container)
                block.container.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            return stack
        }

        let root = NSStackView(views: columnViews)
        root.orientation = columns ? .horizontal : .vertical
        root.alignment = columns ? .top : .leading
        root.distribution = columns ? .fillEqually : .fill
        root.spacing = columns ? 20 : 12
        root.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(root)
        var constraints = [
            root.topAnchor.constraint(equalTo: host.topAnchor),
            root.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ]
        if !columns {
            constraints += columnViews.map { $0.widthAnchor.constraint(equalTo: root.widthAnchor) }
        }
        NSLayoutConstraint.activate(constraints)
        self.root = root
        applyFilter()
    }

    private func makeBlock(range: Range<Int>, section: TrackPageSection?) -> Block {
        let header = section.map {
            DiscHeaderView(label: $0.label, count: $0.range.count, duration: $0.duration)
        }
        let rowStack: NSStackView
        let container: NSView
        if columns {
            let boxed = RoundedRowsView()
            rowStack = boxed.stack
            container = boxed
        } else {
            rowStack = NSStackView()
            rowStack.orientation = .vertical
            rowStack.spacing = 0
            container = rowStack
        }
        for index in range {
            let row = makeRow(index)
            rows[index] = row
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(
                equalTo: rowStack.widthAnchor,
                constant: columns ? -(rowStack.edgeInsets.left + rowStack.edgeInsets.right) : 0
            ).isActive = true
        }
        return Block(range: range, header: header, container: container)
    }

    private func makeRow(_ index: Int) -> DetailTrackRowView {
        let entry = model.entries[index]
        let playing = AudioPlayer.shared.currentTrack?.fileURL
        let row = DetailTrackRowView()
        row.configure(
            number: entry.number,
            title: entry.track.title,
            duration: entry.track.duration,
            loved: LovedTracksService.shared.isLoved(track: entry.track),
            isPlaying: playing == entry.track.fileURL
        )
        row.onDoubleClick = { [weak self] in
            guard let self else { return }
            MidgarLog.info("Playing \(entry.track.title) from \(model.pageName())", category: .playback)
            model.play(model.entries.map(\.track), index)
        }
        row.onToggleLove = {
            Task { _ = await LovedTracksService.shared.toggleLove(track: entry.track) }
        }
        row.onMenu = { [weak self, weak row] in
            self?.model.menu(entry, row)
        }
        return row
    }
}
