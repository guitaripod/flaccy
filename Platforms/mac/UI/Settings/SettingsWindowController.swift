import AppKit
import FlaccyCore

/// The Settings window (⌘,), laid out like System Settings: a searchable list
/// of pages on the left, each led by a colored icon, and the chosen page on
/// the right under its name.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    var onClose: (() -> Void)?

    convenience init() {
        self.init(contentController: SettingsTabViewController())
    }

    convenience init(contentController: NSViewController) {
        let window = NSWindow(contentViewController: contentController)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = String(localized: "Settings")
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        MacTheme.shared.dress(window)
        window.center()
        window.setFrameAutosaveName("FlaccySettingsWindow")
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// `NSWindowController` otherwise retitles the window after the document it
    /// does not have, which is how a settings window ends up called "Untitled".
    /// The tab controller owns the title here.
    override func synchronizeWindowTitleWithDocumentName() {}
}

/// Holds the Settings pages as tabs with no tab bar of their own: the sidebar
/// chooses the page, and `selectedTabViewItemIndex` still opens one from code.
final class SettingsTabViewController: NSTabViewController {

    static let contentSize = NSSize(width: 820, height: 600)
    static let sidebarWidth: CGFloat = 220
    static let titlebarHeight: CGFloat = 52

    private let sidebar = SettingsSidebarView()
    private let paneTitle = NSTextField(labelWithString: "")

    override func loadView() {
        tabStyle = .unspecified
        tabView.tabViewType = .noTabsNoBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        paneTitle.translatesAutoresizingMaskIntoConstraints = false
        paneTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let root = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        root.addSubview(tabView)
        root.addSubview(sidebar)
        root.addSubview(paneTitle)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.contentSize.width),
            root.heightAnchor.constraint(equalToConstant: Self.contentSize.height),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            paneTitle.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 24),
            paneTitle.centerYAnchor.constraint(equalTo: root.topAnchor, constant: Self.titlebarHeight / 2),
            tabView.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.titlebarHeight),
            tabView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addPane(GeneralSettingsPane(), title: String(localized: "General"), symbol: "gearshape.fill", tint: .systemGray)
        addPane(AppearanceSettingsPane(), title: String(localized: "Appearance"), symbol: "paintbrush.fill", tint: .systemPurple)
        addPane(SoundSettingsPane(), title: String(localized: "Sound"), symbol: "waveform", tint: .systemPink)
        addPane(LastFMSettingsPane(), title: "Last.fm", symbol: "dot.radiowaves.left.and.right", tint: .systemRed)
        addPane(NotificationsSettingsPane(), title: String(localized: "Recap"), symbol: "bell.badge.fill", tint: .systemOrange)
        addPane(LibrarySettingsPane(), title: String(localized: "Library"), symbol: "books.vertical.fill", tint: .systemBlue)
        addPane(ServersSettingsPane(), title: String(localized: "Servers"), symbol: "server.rack", tint: .systemGreen)
        addPane(AboutSettingsPane(), title: String(localized: "About"), symbol: "info.circle.fill", tint: .systemIndigo)
        sidebar.onSelect = { [weak self] index in self?.selectedTabViewItemIndex = index }
        sidebar.searchText = { [weak self] index in self?.searchText(ofPaneAt: index) ?? "" }
        sidebar.select(selectedTabViewItemIndex)
    }

    private func addPane(_ controller: NSViewController, title: String, symbol: String, tint: NSColor) {
        controller.title = title
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = MacSymbolImage.image(symbol, accessibilityDescription: title)
        addTabViewItem(item)
        sidebar.addPage(title: title, symbol: symbol, tint: tint)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyTitle(tabViewItems[selectedTabViewItemIndex].label)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        applyTitle(tabViewItem?.label ?? String(localized: "Settings"))
        sidebar.select(selectedTabViewItemIndex)
    }

    private func applyTitle(_ title: String) {
        paneTitle.stringValue = title
        view.window?.title = title
    }

    #if DEBUG
    func debugSearch(_ text: String) {
        sidebar.debugSearch(text)
    }
    #endif

    /// Everything the page at `index` says, folded for the sidebar's search:
    /// its name and every label and control title on it.
    private func searchText(ofPaneAt index: Int) -> String {
        guard tabViewItems.indices.contains(index) else { return "" }
        let item = tabViewItems[index]
        var words = [item.label]
        if let view = item.viewController?.view {
            Self.collectWords(in: view, into: &words)
        }
        return LibrarySearch.haystack(words)
    }

    private static func collectWords(in view: NSView, into words: inout [String]) {
        if let field = view as? NSTextField, !field.isEditable {
            words.append(field.stringValue)
        } else if let button = view as? NSButton {
            words.append(button.title)
        }
        for subview in view.subviews {
            collectWords(in: subview, into: &words)
        }
    }
}

/// The Settings sidebar: a search field over one row per page.
final class SettingsSidebarView: NSVisualEffectView, NSSearchFieldDelegate {

    var onSelect: ((Int) -> Void)?
    var searchText: ((Int) -> String)?

    private let searchField = NSSearchField()
    private let rowStack = NSStackView()
    private var rows: [SettingsSidebarRow] = []
    private var foldedPages: [String]?
    private let nothingLabel = NSTextField(wrappingLabelWithString: String(localized: "No setting matches. Check the spelling or search for fewer words."))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = String(localized: "Search")
        searchField.delegate = self
        searchField.controlSize = .large
        searchField.setAccessibilityIdentifier("settings.search")
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        nothingLabel.font = .systemFont(ofSize: 12)
        nothingLabel.textColor = .secondaryLabelColor
        nothingLabel.alignment = .center
        nothingLabel.isHidden = true
        nothingLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)
        addSubview(rowStack)
        addSubview(nothingLabel)
        MacThemeFillView(.sidebar).install(behind: self)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: SettingsTabViewController.titlebarHeight),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rowStack.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            nothingLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 24),
            nothingLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            nothingLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func addPage(title: String, symbol: String, tint: NSColor) {
        let index = rows.count
        let row = SettingsSidebarRow(title: title, symbol: symbol, tint: tint) { [weak self] in
            self?.onSelect?(index)
        }
        rows.append(row)
        rowStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
    }

    func select(_ index: Int) {
        for (position, row) in rows.enumerated() {
            row.isSelected = position == index
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        applySearch()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if let first = rows.firstIndex(where: { !$0.isHidden }) {
            onSelect?(first)
        }
        return true
    }

    #if DEBUG
    func debugSearch(_ text: String) {
        searchField.stringValue = text
        applySearch()
    }
    #endif

    private func applySearch() {
        let query = LibrarySearch.Query(searchField.stringValue)
        if foldedPages == nil, !query.isEmpty {
            foldedPages = rows.indices.map { searchText?($0) ?? "" }
        }
        for (index, row) in rows.enumerated() {
            row.isHidden = !query.isEmpty && !query.matches(haystack: foldedPages?[index] ?? "")
        }
        nothingLabel.isHidden = rows.contains { !$0.isHidden }
    }
}

/// One page in the Settings sidebar: a colored tile holding the page's symbol,
/// then its name. The selected page wears the accent color.
final class SettingsSidebarRow: NSControl {

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            applyTitleColor()
            needsDisplay = true
            setAccessibilityValue(isSelected)
        }
    }

    /// The selected page's name reads on the accent it lies on: the system's
    /// white on the system's accent, the theme's own on a theme's.
    private func applyTitleColor() {
        let onAccent: NSColor = ThemePalettes.isPainting ? .flaccyOnAccent : .alternateSelectedControlTextColor
        titleLabel.textColor = isSelected ? onAccent : .labelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTitleColor()
    }

    private let titleLabel: NSTextField
    private let choose: () -> Void

    init(title: String, symbol: String, tint: NSColor, choose: @escaping () -> Void) {
        titleLabel = NSTextField(labelWithString: title)
        self.choose = choose
        super.init(frame: .zero)
        let tile = SettingsIconTile(symbol: symbol, tint: tint)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [tile, titleLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityIdentifier("settings.page.\(title)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        choose()
    }

    override func accessibilityPerformPress() -> Bool {
        choose()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.flaccyAccent.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: ThemeShape.radius(7), yRadius: ThemeShape.radius(7)).fill()
    }
}

/// A small rounded tile in one color holding a white symbol, as each row of
/// System Settings is led.
final class SettingsIconTile: NSView {

    private let tint: NSColor

    init(symbol: String, tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        let image = NSImageView()
        image.image = MacSymbolImage.image(symbol)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        image.contentTintColor = .white
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        tint.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: ThemeShape.radius(6), yRadius: ThemeShape.radius(6)).fill()
    }
}

/// A group of settings: its rows on one rounded plate with a hairline between
/// them, as System Settings groups what belongs together.
final class SettingsGroupBox: NSView {

    static let inset: CGFloat = 14

    private var rows: [(row: NSView, line: NSBox?)] = []
    private var watchers: [NSKeyValueObservation] = []

    init(rows: [NSView], joinedToPrevious: (NSView) -> Bool) {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            var line: NSBox?
            if index > 0, !joinedToPrevious(row) {
                let hairline = NSBox()
                hairline.boxType = .separator
                stack.addArrangedSubview(hairline)
                hairline.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                line = hairline
            }
            stack.addArrangedSubview(row)
            self.rows.append((row, line))
            watchers.append(row.observe(\.isHidden) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.followHiddenRows() }
            })
        }
        followHiddenRows()
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Hides the hairline above a hidden row and above the first row shown,
    /// and the whole plate while none of its rows is shown.
    private func followHiddenRows() {
        var shownAny = false
        for (row, line) in rows {
            line?.isHidden = row.isHidden || !shownAny
            shownAny = shownAny || !row.isHidden
        }
        isHidden = !shownAny
    }

    override func draw(_ dirtyRect: NSRect) {
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: ThemeShape.radius(10), yRadius: ThemeShape.radius(10))
        NSColor.flaccyLabel.withAlphaComponent(0.045).setFill()
        plate.fill()
        NSColor.flaccySeparator.setStroke()
        plate.lineWidth = 0.5
        plate.stroke()
    }
}

/// A document view that lays out from the top, so a page shorter than the
/// window sits under its title instead of on the floor.
final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Base pane: a scrolling vertical form with helpers shared by every settings
/// page. A pane adds section labels, rows, explanations and separators to
/// `formStack` in `buildForm`; the base then gathers each section's rows onto
/// one plate under its title.
class SettingsPane: NSViewController {

    static let margin: CGFloat = 24
    private static let sectionIdentifier = NSUserInterfaceItemIdentifier("settings.section")
    private static let separatorIdentifier = NSUserInterfaceItemIdentifier("settings.separator")
    private static let explanationIdentifier = NSUserInterfaceItemIdentifier("settings.explanation")

    static let fullWidthInset = 2 * (margin + SettingsGroupBox.inset)

    let formStack = NSStackView()

    func makeRootView() -> NSView {
        NSView()
    }

    override func loadView() {
        view = makeRootView()
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 14
        formStack.edgeInsets = NSEdgeInsets(top: 4, left: Self.margin, bottom: 24, right: Self.margin)
        formStack.translatesAutoresizingMaskIntoConstraints = false
        let document = SettingsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(formStack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            formStack.topAnchor.constraint(equalTo: document.topAnchor),
            formStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            formStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            formStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        buildForm()
        gatherSections()
    }

    func buildForm() {}

    /// Rebuilds the form as titled plates: a section label starts a group, a
    /// separator ends one, and everything between goes onto one plate.
    private func gatherSections() {
        let built = formStack.arrangedSubviews
        for view in built {
            formStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var rows: [NSView] = []
        func closeGroup() {
            guard !rows.isEmpty else { return }
            let box = SettingsGroupBox(rows: rows) { $0.identifier == Self.explanationIdentifier }
            formStack.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: formStack.widthAnchor, constant: -2 * Self.margin).isActive = true
            rows = []
        }
        for view in built {
            switch view.identifier {
            case Self.separatorIdentifier:
                closeGroup()
            case Self.sectionIdentifier:
                closeGroup()
                guard (view as? NSTextField)?.stringValue != title else { continue }
                formStack.addArrangedSubview(view)
                formStack.setCustomSpacing(8, after: view)
            default:
                rows.append(view)
            }
        }
        closeGroup()
    }

    func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.identifier = Self.sectionIdentifier
        return label
    }

    func explanation(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.identifier = Self.explanationIdentifier
        return label
    }

    func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.identifier = Self.separatorIdentifier
        return box
    }

    @discardableResult
    func addRow(_ views: [NSView], spacing: CGFloat = 8) -> NSView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = spacing
        formStack.addArrangedSubview(row)
        return row
    }

    func addFullWidth(_ view: NSView) {
        formStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: formStack.widthAnchor, constant: -Self.fullWidthInset).isActive = true
    }
}
