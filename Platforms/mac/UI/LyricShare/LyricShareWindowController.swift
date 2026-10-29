import AppKit
import MidgarCore

/// Presents the lyric share window: as a sheet on the window it was asked
/// from, or on its own when there is no such window or it is too small to
/// hold the sheet. Only one is open at a time.
@MainActor
final class LyricShareWindowController: NSWindowController, NSWindowDelegate {

    static let contentSize = NSSize(width: 980, height: 720)
    static let minimumSize = NSSize(width: 820, height: 600)
    private static var active: LyricShareWindowController?

    let content: MacLyricShareViewController
    private var isFinished = false

    @discardableResult
    static func present(_ session: LyricShareSession, from anchor: NSWindow?) -> LyricShareWindowController {
        active?.dismiss()
        let controller = LyricShareWindowController(session: session)
        active = controller
        controller.show(over: anchor ?? NSApp.mainWindow ?? NSApp.keyWindow)
        return controller
    }

    private init(session: LyricShareSession) {
        content = MacLyricShareViewController(session: session)
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = LyricShareCopy.sheetTitle
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minimumSize
        window.setContentSize(Self.contentSize)
        super.init(window: window)
        window.delegate = self
        content.onClose = { [weak self] in self?.dismiss() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    /// Ends the window and everything it started. Safe to call twice.
    func dismiss() {
        guard let window else { return }
        finish()
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        finish()
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        content.teardown()
        if Self.active === self { Self.active = nil }
    }

    private func show(over parent: NSWindow?) {
        guard let window else { return }
        if let parent, parent.isVisible, parent.sheets.isEmpty, Self.fits(window, in: parent) {
            let room = parent.contentLayoutRect.size
            window.setContentSize(NSSize(
                width: min(Self.contentSize.width, room.width - 40),
                height: min(Self.contentSize.height, room.height - 24)))
            parent.beginSheet(window)
            MidgarLog.info("Lyric share opened as a sheet", category: .ui)
        } else {
            window.center()
            showWindow(nil)
            NSApp.activate()
            MidgarLog.info("Lyric share opened as a window", category: .ui)
        }
    }

    private static func fits(_ window: NSWindow, in parent: NSWindow) -> Bool {
        let room = parent.contentLayoutRect.size
        return room.width >= minimumSize.width + 40 && room.height >= minimumSize.height + 24
    }
}
