import AppKit

/// The single main window: unified-toolbar chrome over the split view, with
/// the floating glass transport bar overlaid at the bottom and a local Space
/// key monitor for play/pause that never steals typing from text fields.
final class MainWindowController: NSWindowController {

    private var spaceKeyMonitor: Any?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Flaccy"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 960, height: 600)
        window.center()
        window.setFrameAutosaveName("FlaccyMainWindow")
        window.isReleasedWhenClosed = false

        self.init(window: window)

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        contentViewController = RootContainerViewController()
        installSpaceKeyMonitor()
    }

    deinit {
        if let spaceKeyMonitor {
            NSEvent.removeMonitor(spaceKeyMonitor)
        }
    }

    private func installSpaceKeyMonitor() {
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  event.charactersIgnoringModifiers == " ",
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !(self.window?.firstResponder is NSText)
            else { return event }
            AudioPlayer.shared.togglePlayPause()
            return nil
        }
    }
}

extension MainWindowController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
}

/// Stacks the split view under the floating transport bar and reserves safe
/// area at the bottom so scrolled content never hides behind the glass.
final class RootContainerViewController: NSViewController {

    let splitViewController = MainSplitViewController()
    let transportBarViewController = TransportBarViewController()

    private static let transportHeight: CGFloat = 84
    private static let transportMargin: CGFloat = 12

    override func loadView() {
        view = NSView()

        addChild(splitViewController)
        splitViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitViewController.view)

        addChild(transportBarViewController)
        transportBarViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transportBarViewController.view)

        NSLayoutConstraint.activate([
            splitViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            splitViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            transportBarViewController.view.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Self.transportMargin
            ),
            transportBarViewController.view.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Self.transportMargin
            ),
            transportBarViewController.view.bottomAnchor.constraint(
                equalTo: view.bottomAnchor, constant: -Self.transportMargin
            ),
            transportBarViewController.view.heightAnchor.constraint(
                equalToConstant: Self.transportHeight
            ),
        ])

        splitViewController.view.additionalSafeAreaInsets = NSEdgeInsets(
            top: 0, left: 0, bottom: Self.transportHeight + Self.transportMargin * 2, right: 0
        )
    }
}
