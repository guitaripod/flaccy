import AppKit
import FlaccyCore

/// The songs section of an album or playlist page: the control strip (filter,
/// the playing-song button and the layout switch) over whichever layout the
/// listener chose. The choice is remembered across launches and shared by
/// every song page; a layout is built the first time it is shown.
final class TrackPageSongs: NSObject {

    static let layoutKey = "flaccy.mac.detailLayout"

    let model: TrackPageModel
    let view = NSStackView()

    var hint: ((TrackPageLayout.Layout) -> String?)?

    private weak var frame: TrackPageFrameView?
    private let makeListSurface: (TrackPageModel) -> TrackPageSurface
    private let controls = NSStackView()
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let switcher: NSSegmentedControl
    private let offered: [TrackPageLayout.Layout]
    private let host = NSView()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private var surfaces: [TrackPageLayout.Layout: TrackPageSurface] = [:]
    private var shown: TrackPageSurface?
    private(set) var layout: TrackPageLayout.Layout

    init(
        model: TrackPageModel,
        frame: TrackPageFrameView,
        listSurface: @escaping (TrackPageModel) -> TrackPageSurface
    ) {
        self.model = model
        self.frame = frame
        makeListSurface = listSurface
        offered = TrackPageLayout.Layout.allCases.filter { $0.isOffered(on: model.kind) }
        layout = Self.savedLayout(for: model.kind)
        switcher = NSSegmentedControl(
            images: offered.map { Self.image(for: $0) },
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        super.init()
        buildControls()
        buildView()
        show(layout)
    }

    static func savedLayout(for kind: TrackPageLayout.PageKind) -> TrackPageLayout.Layout {
        TrackPageLayout.Layout(id: UserDefaults.standard.string(forKey: layoutKey) ?? "").resolved(for: kind)
    }

    func update(entries: [TrackPageEntry], sections: [TrackPageSection]?) {
        model.entries = entries
        model.sections = sections
        let empty = entries.isEmpty
        controls.isHidden = empty
        host.isHidden = empty
        let filterable = entries.count >= TrackPageLayout.filterThreshold
        searchField.isHidden = !filterable
        if !filterable && !model.query.isEmpty {
            searchField.stringValue = ""
            model.query = ""
        }
        surfaces = surfaces.filter { $0.value === shown }
        shown?.reload()
        refreshStatus()
        refreshHint()
    }

    func refreshPlaying() {
        shown?.refreshPlaying()
    }

    func refreshLoved() {
        shown?.refreshLoved()
    }

    private static func label(for layout: TrackPageLayout.Layout) -> String {
        switch layout {
        case .list: String(localized: "List layout")
        case .table: String(localized: "Table layout")
        case .columns: String(localized: "Columns layout")
        }
    }

    private static func image(for layout: TrackPageLayout.Layout) -> NSImage {
        let symbol = switch layout {
        case .list: "list.bullet"
        case .table: "tablecells"
        case .columns: "rectangle.split.2x1"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: label(for: layout)) ?? NSImage()
    }

    private func buildControls() {
        searchField.placeholderString = model.kind == .album
            ? String(localized: "Filter this album")
            : String(localized: "Filter this playlist")
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(filterChanged)
        searchField.isHidden = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true

        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = MacColors.tertiaryLabel
        statusLabel.isHidden = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let jump = NSButton(
            image: NSImage(
                systemSymbolName: "scope", accessibilityDescription: String(localized: "Show the playing song")
            ) ?? NSImage(),
            target: self,
            action: #selector(locatePlaying)
        )
        jump.bezelStyle = .texturedRounded
        jump.toolTip = String(localized: "Show the playing song")
        jump.setAccessibilityLabel(String(localized: "Show the playing song"))

        switcher.target = self
        switcher.action = #selector(layoutPicked)
        switcher.segmentStyle = .texturedRounded
        for (index, candidate) in offered.enumerated() {
            switcher.setToolTip(Self.label(for: candidate), forSegment: index)
            switcher.setWidth(34, forSegment: index)
        }
        switcher.selectedSegment = offered.firstIndex(of: layout) ?? 0

        controls.orientation = .horizontal
        controls.spacing = 10
        controls.alignment = .centerY
        for item in [searchField, statusLabel, spacer, jump, switcher] {
            controls.addArrangedSubview(item)
        }
    }

    private func buildView() {
        hintLabel.font = .systemFont(ofSize: 11.5)
        hintLabel.textColor = MacColors.tertiaryLabel
        hintLabel.isHidden = true

        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 16
        for item in [controls, host, hintLabel] {
            view.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        }
        host.translatesAutoresizingMaskIntoConstraints = false
    }

    private func surface(for layout: TrackPageLayout.Layout) -> TrackPageSurface {
        if let existing = surfaces[layout] { return existing }
        let built: TrackPageSurface
        switch layout {
        case .list:
            built = makeListSurface(model)
        case .table:
            let table = TrackTableSurface(model: model)
            table.onSorted = { [weak self] in self?.frame?.scrollToTop() }
            built = table
        case .columns:
            built = TrackBlocksSurface(model: model, columns: true)
        }
        surfaces[layout] = built
        return built
    }

    private func show(_ layout: TrackPageLayout.Layout) {
        self.layout = layout
        switcher.selectedSegment = offered.firstIndex(of: layout) ?? 0
        shown?.view.removeFromSuperview()
        let next = surface(for: layout)
        shown = next
        next.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: host.topAnchor),
            next.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            next.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        next.reload()
        refreshHint()
    }

    private func refreshHint() {
        let text = model.entries.isEmpty ? nil : hint?(layout)
        hintLabel.stringValue = text ?? ""
        hintLabel.isHidden = text == nil
    }

    private func refreshStatus() {
        guard !model.query.isEmpty else {
            statusLabel.isHidden = true
            return
        }
        let shownCount = model.matchCount
        statusLabel.stringValue = shownCount == 0
            ? String(localized: "No songs match")
            : String(localized: "\(shownCount) of \(model.entries.count)")
        statusLabel.isHidden = false
    }

    private func setQuery(_ text: String) {
        model.query = text.lowercased()
        shown?.applyFilter()
        refreshStatus()
    }

    @objc private func filterChanged() {
        setQuery(searchField.stringValue)
    }

    @objc private func layoutPicked() {
        guard offered.indices.contains(switcher.selectedSegment) else { return }
        let picked = offered[switcher.selectedSegment]
        guard picked != layout else { return }
        UserDefaults.standard.set(picked.id, forKey: Self.layoutKey)
        show(picked)
        frame?.scrollToTop()
    }

    @objc func locatePlaying() {
        let window = view.window
        guard let current = AudioPlayer.shared.currentTrack else {
            MacToast.show(String(localized: "Nothing is playing"), in: window)
            return
        }
        guard let index = model.entries.firstIndex(where: { $0.track.fileURL == current.fileURL }) else {
            let message = model.kind == .album
                ? String(localized: "\u{201C}\(current.title)\u{201D} isn't on \(model.pageName())")
                : String(localized: "\u{201C}\(current.title)\u{201D} isn't in this playlist")
            MacToast.show(message, in: window)
            return
        }
        if !model.query.isEmpty {
            searchField.stringValue = ""
            setQuery("")
        }
        guard let shown, let frame else { return }
        frame.layoutSubtreeIfNeeded()
        guard let rect = shown.frame(ofEntry: index) else { return }
        frame.reveal(rect, in: shown.view)
    }

    #if DEBUG
    func debugFilter(_ text: String) {
        searchField.stringValue = text
        setQuery(text)
    }

    func debugSort(column: String, ascending: Bool) {
        guard let table = shown as? TrackTableSurface,
              let column = TrackTableSurface.Column(rawValue: column) else { return }
        table.debugSort(column, ascending: ascending)
    }

    var debugScrollOffset: CGFloat? {
        frame.map { $0.scrollView.contentView.bounds.origin.y + $0.scrollView.contentInsets.top }
    }

    func debugScroll(to y: CGFloat) {
        guard let scrollView = frame?.scrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func debugPick(_ layout: TrackPageLayout.Layout) {
        guard let index = offered.firstIndex(of: layout) else { return }
        switcher.selectedSegment = index
        layoutPicked()
    }

    func debugChoose(_ layout: TrackPageLayout.Layout) {
        guard layout != self.layout, layout.isOffered(on: model.kind) else { return }
        show(layout)
        frame?.scrollToTop()
    }
    #endif
}
