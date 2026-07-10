import AppKit

/// Sidebar | content | inspector shell. The inspector hosts the live queue
/// and lyrics panels; the queue/lyrics toggles collapse and expand it. The
/// immersive Now Playing surface is managed here as a full-window overlay,
/// and while it is up the queue/lyrics toggles route to its in-overlay
/// panels instead of the inspector.
final class MainSplitViewController: NSSplitViewController {

    let sidebarViewController = SidebarViewController()
    let contentRouter = ContentRouter()
    private let inspectorHost = InspectorHostViewController()

    var inspectorContentView: NSView { inspectorHost.view }
    private var inspectorItem: NSSplitViewItem?
    private var nowPlayingController: NowPlayingViewController?

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

        let inspector = NSSplitViewItem(inspectorWithViewController: inspectorHost)
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleToggleNowPlaying), name: .flaccyToggleNowPlaying, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleShowSection(_ notification: Notification) {
        guard let raw = notification.userInfo?[SectionNotificationKey.section] as? Int,
              let section = SidebarSection(rawValue: raw) else { return }
        closeNowPlaying()
        sidebarViewController.select(section)
    }

    @objc private func handleToggleQueue() {
        if let nowPlayingController {
            nowPlayingController.togglePanel(.queue)
            return
        }
        toggleInspector(mode: .queue)
    }

    @objc private func handleToggleLyrics() {
        if let nowPlayingController {
            nowPlayingController.togglePanel(.lyrics)
            return
        }
        toggleInspector(mode: .lyrics)
    }

    @objc private func handleToggleNowPlaying() {
        if nowPlayingController != nil {
            closeNowPlaying()
        } else {
            openNowPlaying()
        }
    }

    private func openNowPlaying() {
        guard nowPlayingController == nil, let contentView = view.window?.contentView else { return }
        let controller = NowPlayingViewController()
        controller.onClose = { [weak self] in
            self?.closeNowPlaying()
        }
        nowPlayingController = controller
        let overlay = controller.view
        overlay.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        controller.viewDidAppear()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            overlay.alphaValue = 1
        } else {
            overlay.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                overlay.animator().alphaValue = 1
            }
        }
        AppLogger.info("Now Playing immersive opened", category: .ui)
    }

    private func closeNowPlaying() {
        guard let controller = nowPlayingController else { return }
        nowPlayingController = nil
        let overlay = controller.view
        let finish = {
            controller.viewWillDisappear()
            overlay.removeFromSuperview()
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finish()
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                overlay.animator().alphaValue = 0
            }, completionHandler: finish)
        }
        view.window?.makeFirstResponder(nil)
        AppLogger.info("Now Playing immersive closed", category: .ui)
    }
}

/// Hosts the queue or lyrics panel in the inspector column, creating each
/// panel once and swapping which one is installed.
final class InspectorHostViewController: NSViewController {

    enum Mode {
        case queue
        case lyrics

        var title: String {
            switch self {
            case .queue: "Up Next"
            case .lyrics: "Lyrics"
            }
        }
    }

    private(set) var mode: Mode = .queue
    private lazy var queuePanel = QueuePanelViewController()
    private lazy var lyricsPanel = LyricsPanelViewController()
    private let titleLabel = NSTextField(labelWithString: "")
    private let contentContainer = NSView()
    private var installedChild: NSViewController?

    override func loadView() {
        view = NSView()

        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            contentContainer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        apply(mode: mode)
    }

    func show(_ mode: Mode) {
        self.mode = mode
        if isViewLoaded {
            apply(mode: mode)
        }
    }

    private func apply(mode: Mode) {
        titleLabel.stringValue = mode.title
        let next: NSViewController = mode == .queue ? queuePanel : lyricsPanel
        guard next !== installedChild else { return }
        if let installedChild {
            installedChild.view.removeFromSuperview()
            installedChild.removeFromParent()
        }
        addChild(next)
        next.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(next.view)
        NSLayoutConstraint.activate([
            next.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            next.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            next.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        installedChild = next
    }
}

extension MainSplitViewController {

    private func toggleInspector(mode: InspectorHostViewController.Mode) {
        guard let inspectorItem else { return }
        if !inspectorItem.isCollapsed, inspectorHost.mode == mode {
            inspectorItem.animator().isCollapsed = true
            return
        }
        inspectorHost.show(mode)
        inspectorItem.animator().isCollapsed = false
        AppLogger.info("Inspector expanded (\(mode.title))", category: .ui)
    }
}
