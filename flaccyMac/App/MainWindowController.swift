import AppKit
import Combine
import FlaccyCore
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
        if Self.debugWindowSize() == nil {
            window.setFrameAutosaveName("FlaccyMainWindow")
        }
        window.isReleasedWhenClosed = false

        self.init(window: window)

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        contentViewController = RootContainerViewController()
        if let size = Self.debugWindowSize() {
            window.setContentSize(size)
            window.center()
        }
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

    /// DEBUG-only fixed content size for the screenshot rig, parsed from a
    /// `--window-size 1440x900` launch argument so captures are exactly the
    /// aspect the Mac App Store expects regardless of any saved frame.
    private static func debugWindowSize() -> NSSize? {
        #if DEBUG
        guard let index = CommandLine.arguments.firstIndex(of: "--window-size"),
              index + 1 < CommandLine.arguments.count else { return nil }
        let parts = CommandLine.arguments[index + 1].lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { return nil }
        return NSSize(width: width, height: height)
        #else
        return nil
        #endif
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
        item.searchField.placeholderString = String(localized: "Search library")
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
///
/// The status strip lives here rather than inside the content column on
/// purpose: the Now Playing overlay takes the whole split view, and a scan
/// surface underneath it is a scan surface nobody sees. Being a later sibling
/// is not enough to stay in front of it — the overlay is installed on this very
/// view and `addSubview(_:)` lands it frontmost — so the strip is re-raised
/// every time anything else joins the stack.
final class RootContainerViewController: NSViewController {

    let splitViewController = MainSplitViewController()
    let transportBarViewController = TransportBarViewController()

    private let statusStrip = MacStatusStripView()
    private var surfaceCancellable: AnyCancellable?

    private static let transportHeight: CGFloat = 84
    private static let transportMargin: CGFloat = 12
    private static let stripInset: CGFloat = 20
    private static let stripWidth: CGFloat = 320

    override func loadView() {
        let container = AudioDropView()
        container.onSubviewAdded = { [weak self] subview in
            self?.raiseStatusStrip(above: subview)
        }
        view = container

        addChild(splitViewController)
        splitViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitViewController.view)

        view.addSubview(statusStrip, positioned: .above, relativeTo: splitViewController.view)
        NSLayoutConstraint.activate([
            statusStrip.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor, constant: Self.stripInset
            ),
            statusStrip.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Self.stripInset
            ),
            statusStrip.bottomAnchor.constraint(
                equalTo: view.bottomAnchor, constant: -(Self.transportHeight + Self.stripInset)
            ),
            statusStrip.widthAnchor.constraint(equalToConstant: Self.stripWidth),
        ])

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

    override func viewDidLoad() {
        super.viewDidLoad()
        surfaceCancellable = MacLibrarySurfaceModel.shared.state
            .removeDuplicates()
            .sink { [weak self] state in
                self?.render(state)
            }
        render(MacLibrarySurfaceModel.shared.state.value)
    }

    /// The strip carries the ambient surface and nothing else. A Debut has its
    /// own stage in the onboarding panel, and `.none` genuinely means silence —
    /// a relaunch that finds no work due shows no chrome at all.
    private func render(_ state: MacLibrarySurfaceModel.State) {
        guard state.surface == .ambient else {
            statusStrip.setVisible(false)
            return
        }
        statusStrip.update(state.load.isActive ? .load(state.load, state.fraction) : .job(state.job))
        statusStrip.setVisible(true)
        raiseStatusStrip()
    }

    /// Answers a newcomer to the stack — in practice the full-window Now Playing
    /// overlay, which `MainSplitViewController` installs on this view — by
    /// lifting the strip back over it. Ignores the strip's own re-insertion so
    /// the raise cannot recurse.
    private func raiseStatusStrip(above subview: NSView) {
        guard subview !== statusStrip else { return }
        raiseStatusStrip()
    }

    /// Moves the strip to the front of its superview's z-order. Re-inserting a
    /// view that is already a subview only reorders it: constraints and frame
    /// survive, so this is safe to call on every render.
    private func raiseStatusStrip() {
        guard statusStrip.superview === view else { return }
        view.addSubview(statusStrip, positioned: .above, relativeTo: nil)
    }
}

/// Full-window drop target: highlights on drag-over with audio files or
/// folders, copies them into the library root and triggers a rescan.
final class AudioDropView: NSView {

    /// Reports every view added on top, so the owner can keep a floating
    /// surface in front of a full-window overlay it does not install itself.
    var onSubviewAdded: ((NSView) -> Void)?

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

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        onSubviewAdded?(subview)
    }

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
        guard !LibraryRoot.shared.isFallbackActive else {
            MacToast.show(String(localized: "Music folder unavailable — reconnect the drive or choose a new folder."), style: .error, in: window)
            return false
        }
        isImporting = true
        AppLogger.info("Importing \(urls.count) dropped item(s)", category: .content)
        MacToast.show(
            String(localized: "Importing \(urls.count) items…"), style: .info, in: window
        )
        Task { [weak self] in
            let outcome = await Library.shared.importFiles(from: urls)
            self?.isImporting = false
            MacToast.showImportOutcome(outcome, in: self?.window)
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
