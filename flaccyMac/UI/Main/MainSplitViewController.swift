import AppKit

/// Sidebar | content | inspector shell. The inspector column is a Stage A
/// placeholder that the queue and lyrics panels replace in a later stage; the
/// queue/lyrics toggles already collapse and expand it so the window chrome
/// behaves like the finished app.
final class MainSplitViewController: NSSplitViewController {

    let sidebarViewController = SidebarViewController()
    let contentRouter = ContentRouter()
    private let inspectorPlaceholder = InspectorPlaceholderViewController()
    private var inspectorItem: NSSplitViewItem?

    override func viewDidLoad() {
        super.viewDidLoad()

        sidebarViewController.onSelect = { [weak self] section in
            self?.contentRouter.show(section)
        }

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 280
        addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: contentRouter)
        contentItem.minimumThickness = 480
        addSplitViewItem(contentItem)

        let inspector = NSSplitViewItem(inspectorWithViewController: inspectorPlaceholder)
        inspector.minimumThickness = 260
        inspector.maximumThickness = 340
        inspector.isCollapsed = true
        inspector.canCollapse = true
        addSplitViewItem(inspector)
        inspectorItem = inspector

        if contentRouter.currentSection == nil {
            contentRouter.show(.albums)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowSection(_:)), name: .flaccyShowSection, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleToggleQueue), name: .flaccyToggleQueue, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleToggleLyrics), name: .flaccyToggleLyrics, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleShowSection(_ notification: Notification) {
        guard let raw = notification.userInfo?[SectionNotificationKey.section] as? Int,
              let section = SidebarSection(rawValue: raw) else { return }
        sidebarViewController.select(section)
    }

    @objc private func handleToggleQueue() {
        toggleInspector(mode: .queue)
    }

    @objc private func handleToggleLyrics() {
        toggleInspector(mode: .lyrics)
    }

    private func toggleInspector(mode: InspectorPlaceholderViewController.Mode) {
        guard let inspectorItem else { return }
        if !inspectorItem.isCollapsed, inspectorPlaceholder.mode == mode {
            inspectorItem.animator().isCollapsed = true
            return
        }
        inspectorPlaceholder.mode = mode
        inspectorItem.animator().isCollapsed = false
    }
}

final class InspectorPlaceholderViewController: NSViewController {

    enum Mode {
        case queue
        case lyrics

        var title: String {
            switch self {
            case .queue: "Up Next"
            case .lyrics: "Lyrics"
            }
        }

        var symbolName: String {
            switch self {
            case .queue: "list.bullet"
            case .lyrics: "quote.bubble"
            }
        }
    }

    var mode: Mode = .queue {
        didSet { applyMode() }
    }

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "Arriving in a later stage.")

    override func loadView() {
        view = NSView()

        icon.symbolConfiguration = .init(pointSize: 32, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [icon, titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        applyMode()
    }

    private func applyMode() {
        guard isViewLoaded else { return }
        icon.image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: nil)
        titleLabel.stringValue = mode.title
    }
}
