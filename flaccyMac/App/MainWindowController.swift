import AppKit
import UniformTypeIdentifiers

/// The single main window: unified-toolbar chrome with a library search
/// field, drag-and-drop import of audio files anywhere in the window, the
/// floating glass transport bar at the bottom and a local Space key monitor
/// for play/pause that never steals typing from text fields.
final class MainWindowController: NSWindowController {

    private var spaceKeyMonitor: Any?
    private var searchItem: NSSearchToolbarItem?

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(focusSearchField), name: .flaccyFocusSearch, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let spaceKeyMonitor {
            NSEvent.removeMonitor(spaceKeyMonitor)
        }
    }

    @objc private func focusSearchField() {
        window?.makeKeyAndOrderFront(nil)
        searchItem?.beginSearchInteraction()
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        LibrarySearchState.update(sender.stringValue)
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

    private static let searchIdentifier = NSToolbarItem.Identifier("LibrarySearch")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.searchIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.searchIdentifier else { return nil }
        let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
        item.searchField.placeholderString = "Search library"
        item.searchField.sendsSearchStringImmediately = true
        item.searchField.target = self
        item.searchField.action = #selector(searchFieldChanged(_:))
        item.preferredWidthForSearchField = 220
        item.resignsFirstResponderWithCancel = true
        searchItem = item
        return item
    }
}

/// Stacks the split view under the floating transport bar, reserves safe
/// area at the bottom so scrolled content never hides behind the glass, and
/// accepts audio file/folder drops that import into the library root.
final class RootContainerViewController: NSViewController {

    let splitViewController = MainSplitViewController()
    let transportBarViewController = TransportBarViewController()

    private static let transportHeight: CGFloat = 84
    private static let transportMargin: CGFloat = 12

    override func loadView() {
        view = AudioDropView()

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

/// Full-window drop target: highlights on drag-over with audio files or
/// folders, copies them into the library root and triggers a rescan.
final class AudioDropView: NSView {

    private let highlight = NSView()
    private var isImporting = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])

        highlight.wantsLayer = true
        highlight.layer?.borderColor = NSColor.controlAccentColor.cgColor
        highlight.layer?.borderWidth = 3
        highlight.layer?.cornerRadius = 14
        highlight.layer?.cornerCurve = .continuous
        highlight.isHidden = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !droppableURLs(from: sender).isEmpty else { return [] }
        highlight.isHidden = false
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlight.isHidden = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        highlight.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight.isHidden = true
        let urls = droppableURLs(from: sender)
        guard !urls.isEmpty, !isImporting else { return false }
        isImporting = true
        AppLogger.info("Importing \(urls.count) dropped item(s)", category: .content)
        MacToast.show(
            "Importing \(urls.count) item\(urls.count == 1 ? "" : "s")…", style: .info, in: window
        )
        Task { [weak self] in
            await Library.shared.importFiles(from: urls)
            self?.isImporting = false
            MacToast.show("Import finished", style: .success, in: self?.window)
        }
        return true
    }

    private static let audioExtensions: Set<String> = [
        "flac", "m4a", "aac", "alac", "mp3", "wav", "aiff", "aif", "caf",
    ]

    private func droppableURLs(from info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return false
            }
            return isDirectory.boolValue
                || Self.audioExtensions.contains(url.pathExtension.lowercased())
        }
    }
}
