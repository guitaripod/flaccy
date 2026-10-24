import AppKit

/// The equalizer's own window: opened from the transport bar's quick panel,
/// the Playback menu or ⌥⌘E, and left open beside the library while music
/// plays, the way Music's equalizer window is. It always draws over the dark
/// artwork wash, like the other artwork screens, and owns the undo manager its
/// gestures register with.
@MainActor
final class MacEqualizerWindowController: NSWindowController, NSWindowDelegate {

    static let shared = MacEqualizerWindowController()

    private let undo = UndoManager()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = EqualizerCopy.title
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.minSize = Self.minimumSize(at: MacInterfaceScale.current)
        window.center()
        window.setFrameAutosaveName("FlaccyEqualizerWindow")
        self.init(window: window)
        window.delegate = self
        contentViewController = MacEqualizerViewController()
        NotificationCenter.default.addObserver(self, selector: #selector(interfaceScaleChanged), name: .flaccyInterfaceScaleChanged, object: nil)
    }

    private static let baseMinimumSize = NSSize(width: 1200, height: 700)

    private static func minimumSize(at scale: CGFloat) -> NSSize {
        let grown = NSSize(width: baseMinimumSize.width * scale, height: baseMinimumSize.height * scale)
        let visible = NSScreen.main?.visibleFrame.size ?? grown
        return NSSize(width: min(grown.width, visible.width), height: min(grown.height, visible.height))
    }

    @objc private func interfaceScaleChanged() {
        guard let window else { return }
        window.minSize = Self.minimumSize(at: MacInterfaceScale.current)
        var frame = window.frame
        frame.size.width = max(frame.width, window.minSize.width)
        frame.size.height = max(frame.height, window.minSize.height)
        if frame.size != window.frame.size { window.setFrame(frame, display: true, animate: true) }
    }

    var isVisible: Bool {
        window?.isVisible == true
    }

    func show() {
        if contentViewController == nil {
            contentViewController = MacEqualizerViewController()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        contentViewController = nil
        undo.removeAllActions()
    }

    func toggle() {
        if isVisible, window?.isKeyWindow == true {
            window?.orderOut(nil)
        } else {
            show()
        }
    }

    nonisolated func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        MainActor.assumeIsolated { undo }
    }

    override func synchronizeWindowTitleWithDocumentName() {}
}
