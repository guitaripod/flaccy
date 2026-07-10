import AppKit

/// The standard macOS Settings window (⌘,): toolbar-style tabs hosting the
/// General, Last.fm, Recap & Notifications, Library, and About panes.
final class SettingsWindowController: NSWindowController {

    convenience init() {
        let tabController = SettingsTabViewController()
        let window = NSWindow(contentViewController: tabController)
        window.styleMask = [.titled, .closable]
        window.title = "General"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.center()
        window.setFrameAutosaveName("FlaccySettingsWindow")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

final class SettingsTabViewController: NSTabViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar

        addPane(GeneralSettingsPane(), title: "General", symbol: "gearshape")
        addPane(LastFMSettingsPane(), title: "Last.fm", symbol: "dot.radiowaves.left.and.right")
        addPane(NotificationsSettingsPane(), title: "Recap", symbol: "bell.badge")
        addPane(LibrarySettingsPane(), title: "Library", symbol: "folder")
        addPane(AboutSettingsPane(), title: "About", symbol: "info.circle")
    }

    private func addPane(_ controller: NSViewController, title: String, symbol: String) {
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        addTabViewItem(item)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.title = tabViewItem?.label ?? "Settings"
    }
}

/// Base pane: a fixed-width vertical form stack with helpers shared by every
/// settings page.
class SettingsPane: NSViewController {

    let formStack = NSStackView()

    override func loadView() {
        view = NSView()
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 14
        formStack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        formStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(formStack)
        NSLayoutConstraint.activate([
            formStack.topAnchor.constraint(equalTo: view.topAnchor),
            formStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: 560),
        ])
        buildForm()
    }

    func buildForm() {}

    func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    func explanation(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        return label
    }

    func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    func addRow(_ views: [NSView], spacing: CGFloat = 8) {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = spacing
        formStack.addArrangedSubview(row)
    }

    func addFullWidth(_ view: NSView) {
        formStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: formStack.widthAnchor, constant: -56).isActive = true
    }
}
