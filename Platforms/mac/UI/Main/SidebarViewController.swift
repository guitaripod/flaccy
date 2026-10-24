import AppKit

/// Source-list sidebar: Library and Discover groups over the full-height
/// window material, selection routed to the content router.
final class SidebarViewController: NSViewController {

    var onSelect: ((SidebarSection) -> Void)?

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let groups: [(title: String, sections: [SidebarSection])] = [
        (String(localized: "Library"), [.albums, .songs, .artists, .playlists]),
        (String(localized: "Discover"), [.wantlist, .charts, .yearInMusic, .listeningGuide]),
    ]

    override func loadView() {
        view = NSView()

        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.allowsEmptySelection = false
        outlineView.dataSource = self
        outlineView.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        select(.albums)
    }

    func select(_ section: SidebarSection) {
        let row = outlineView.row(forItem: section)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    var visibleRowCount: Int {
        outlineView.numberOfRows
    }
}

extension SidebarViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return groups.count }
        if let group = item as? String {
            return groups.first { $0.title == group }?.sections.count ?? 0
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return groups[index].title }
        let group = item as? String ?? ""
        return groups.first { $0.title == group }?.sections[index] ?? SidebarSection.albums
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is String
    }
}

extension SidebarViewController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is String
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is SidebarSection
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? String {
            let identifier = NSUserInterfaceItemIdentifier("group")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? Self.makeGroupCell(identifier: identifier)
            cell.textField?.stringValue = group
            return cell
        }
        guard let section = item as? SidebarSection else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("row")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarRowCellView
            ?? SidebarRowCellView(identifier: identifier)
        cell.configure(title: section.title, symbolName: section.symbolName)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let section = outlineView.item(atRow: outlineView.selectedRow) as? SidebarSection else { return }
        onSelect?(section)
    }

    private static func makeGroupCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        cell.addSubview(text)
        cell.textField = text

        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// A sidebar row whose icon is deliberately not the cell's `imageView`.
/// `NSTableCellView` re-applies a symbol configuration to its `imageView` from
/// inside its own layout pass, which dirties the constraints it is being laid
/// out against; under the zoom host's scaled bounds that loops until AppKit
/// aborts with an exception. Owning the icon keeps AppKit out of it, so the
/// tint that the cell would have followed for selection is applied here.
final class SidebarRowCellView: NSTableCellView {

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(label)
        textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyTint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTint() }
    }

    func configure(title: String, symbolName: String) {
        label.stringValue = title
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
    }

    /// White on the emphasized selection, the label colour otherwise.
    private func applyTint() {
        icon.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
    }
}
