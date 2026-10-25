import AppKit
import FlaccyCore

/// The sheet that arranges Home: drag a row to move its section, tick the box
/// to show it. Nothing is saved until Done.
final class MacHomeCustomizeViewController: NSViewController {

    private static let rowType = NSPasteboard.PasteboardType("com.midgarcorp.flaccy.home.section")
    private static let rowHeight: CGFloat = 56

    private let table = NSTableView()
    private let restoreButton = NSButton(title: HomeCopy.restoreDefault, target: nil, action: nil)
    private var layout: HomeLayout

    init(layout: HomeLayout = HomeLayoutStore.shared.layout) {
        self.layout = layout
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var workingLayout: HomeLayout { layout }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: HomeCopy.customizeHome)
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let intro = NSTextField(wrappingLabelWithString: HomeCopy.editIntro)
        intro.font = .systemFont(ofSize: 13)
        intro.textColor = .secondaryLabelColor
        intro.isSelectable = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        table.registerForDraggedTypes([Self.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(HomeCopy.customizeHome)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.layer?.cornerCurve = .continuous
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSTextField(wrappingLabelWithString: HomeCopy.editFooter)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.isSelectable = false

        restoreButton.target = self
        restoreButton.action = #selector(restoreDefault)
        restoreButton.bezelStyle = .rounded
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let done = NSButton(title: String(localized: "Done"), target: self, action: #selector(done))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let spacer = NSView()
        let buttons = NSStackView(views: [restoreButton, spacer, cancel, done])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [title, intro, scroll, footer, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(16, after: intro)
        stack.setCustomSpacing(10, after: scroll)
        stack.setCustomSpacing(18, after: footer)
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let rows = CGFloat(HomeSection.allCases.count)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 480),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            scroll.heightAnchor.constraint(equalToConstant: rows * Self.rowHeight),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
        ])
        view = root
        refreshRestore()
    }

    @objc private func restoreDefault() {
        layout = .standard
        table.reloadData()
        refreshRestore()
    }

    @objc private func cancel() {
        dismiss(nil)
    }

    @objc private func done() {
        HomeLayoutStore.shared.layout = layout
        dismiss(nil)
    }

    @objc private func visibilityChanged(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard layout.order.indices.contains(row) else { return }
        layout = layout.setting(layout.order[row], visible: sender.state == .on)
        refreshRestore()
    }

    private func refreshRestore() {
        restoreButton.isEnabled = !layout.isStandard
    }

    func move(from source: Int, to destination: Int) {
        layout = layout.moving(from: source, to: destination)
        table.reloadData()
        refreshRestore()
    }
}

extension MacHomeCustomizeViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        layout.order.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard layout.order.indices.contains(row) else { return nil }
        let section = layout.order[row]
        let view = MacHomeCustomizeRow()
        view.configure(section: section, visible: layout.isVisible(section), target: self, action: #selector(visibilityChanged(_:)))
        return view
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let text = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.rowType),
              let source = Int(text) else { return false }
        let destination = row > source ? row - 1 : row
        layout = layout.moving(from: source, to: destination)
        tableView.reloadData()
        refreshRestore()
        return true
    }
}

/// One line of the sheet: a checkbox, the section's name and what it holds,
/// and a grip that says the row can be dragged.
final class MacHomeCustomizeRow: NSView {

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let grip = NSImageView(image: MacSymbolImage.configured("line.3.horizontal", pointSize: 13, weight: .regular) ?? NSImage())
        grip.contentTintColor = .tertiaryLabelColor
        grip.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        for subview in [checkbox, text, grip, separator] { addSubview(subview) }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: grip.leadingAnchor, constant: -12),
            grip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            grip.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(section: HomeSection, visible: Bool, target: AnyObject, action: Selector) {
        title.stringValue = HomeCopy.title(for: section)
        subtitle.stringValue = HomeCopy.editSubtitle(for: section)
        checkbox.state = visible ? .on : .off
        checkbox.target = target
        checkbox.action = action
        checkbox.setAccessibilityLabel(HomeCopy.title(for: section))
        title.textColor = visible ? .labelColor : .secondaryLabelColor
    }
}
