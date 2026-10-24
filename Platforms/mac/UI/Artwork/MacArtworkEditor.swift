import AppKit
import MidgarCore

/// Opens the artwork editor as a sheet on a window and reports how it ended
/// with the toast the rest of the app uses. One editor at a time, and never
/// over a sheet that is already up.
@MainActor
enum MacArtworkEditor {

    private static weak var activeWindow: NSWindow?

    private static let baseContentSize = NSSize(width: 960, height: 760)
    private static let minimumContentSize = NSSize(width: 760, height: 600)
    private static let parentMargin: CGFloat = 60

    @discardableResult
    static func present(
        for album: Album, initial: ArtworkInput? = nil, from window: NSWindow?
    ) -> ArtworkEditorViewController? {
        present(for: ArtworkSubject(album: album), initial: initial, from: window)
    }

    @discardableResult
    static func present(
        forPlaylist playlist: PlaylistRecord, tracks: [Track], initial: ArtworkInput? = nil, from window: NSWindow?
    ) -> ArtworkEditorViewController? {
        guard let id = playlist.id else { return nil }
        let subject = ArtworkSubject(playlistId: id, name: playlist.name, tracks: tracks)
        return present(for: subject, initial: initial, from: window)
    }

    @discardableResult
    static func present(
        for subject: ArtworkSubject, initial: ArtworkInput? = nil, from window: NSWindow?
    ) -> ArtworkEditorViewController? {
        guard let parent = window ?? NSApp.keyWindow ?? NSApp.mainWindow,
              parent.attachedSheet == nil, activeWindow == nil
        else {
            NSSound.beep()
            return nil
        }
        let controller = ArtworkEditorViewController(subject: subject, initial: initial)
        let sheet = NSWindow(contentViewController: controller)
        sheet.styleMask = [.titled, .resizable]
        sheet.appearance = NSAppearance(named: .darkAqua)
        sheet.isReleasedWhenClosed = false
        let sizes = contentSizes(in: parent)
        sheet.contentMinSize = sizes.minimum
        sheet.setContentSize(sizes.preferred)
        activeWindow = sheet

        var outcome = ArtworkEditorViewController.Outcome.cancelled
        controller.onFinish = { [weak parent, weak sheet] result in
            outcome = result
            guard let parent, let sheet else { return }
            parent.endSheet(sheet)
        }
        parent.beginSheet(sheet) { [weak parent] _ in
            MainActor.assumeIsolated {
                activeWindow = nil
                guard let parent else { return }
                announce(outcome, for: subject, in: parent)
            }
        }
        return controller
    }

    private static func announce(
        _ outcome: ArtworkEditorViewController.Outcome, for subject: ArtworkSubject, in window: NSWindow
    ) {
        switch outcome {
        case .saved:
            MacToast.show(String(localized: "Artwork updated"), style: .success, in: window)
        case .restored:
            let message = subject.isPlaylist
                ? String(localized: "Automatic cover restored")
                : String(localized: "Original artwork restored")
            MacToast.show(message, style: .success, in: window)
        case .cancelled:
            break
        }
    }

    /// The two cover items every playlist menu carries: Edit Cover…, and Use
    /// Automatic Cover while the person's own picture is in place.
    static func coverMenuItems(for playlist: PlaylistRecord, tracks: [Track], window: NSWindow?) -> [NSMenuItem] {
        guard let id = playlist.id else { return [] }
        var items: [NSMenuItem] = [
            ClosureMenuItem(title: String(localized: "Edit Cover…"), systemImage: "photo") { [weak window] in
                present(forPlaylist: playlist, tracks: tracks, from: window)
            },
        ]
        if DatabaseManager.shared.hasPlaylistCover(id: id) {
            items.append(ClosureMenuItem(title: String(localized: "Use Automatic Cover"), systemImage: "arrow.uturn.backward") { [weak window] in
                confirmUseAutomaticCover(for: playlist, in: window)
            })
        }
        return items
    }

    /// Asks before a playlist gives up its chosen picture for the automatic
    /// album mosaic, then does it and says so, so the list, the page and the
    /// editor all end the same way.
    static func confirmUseAutomaticCover(for playlist: PlaylistRecord, in window: NSWindow?) {
        guard let id = playlist.id, let window else { return }
        let subject = ArtworkSubject(playlistId: id, name: playlist.name, tracks: [])
        let alert = NSAlert()
        alert.messageText = String(localized: "Use the automatic cover?")
        alert.informativeText = String(localized: "Your chosen picture will be removed and the playlist goes back to a mosaic of its albums.")
        alert.addButton(withTitle: String(localized: "Use Automatic Cover")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak window] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                do {
                    try await Task.detached { try AlbumArtworkEditor.reset(subject) }.value
                    MacToast.show(String(localized: "Automatic cover restored"), style: .success, in: window)
                } catch {
                    MidgarLog.error("Resetting playlist cover failed: \(error.localizedDescription)", category: .database)
                    MacToast.show(String(localized: "Couldn't restore the automatic cover — the library database couldn't be written. Check free disk space and try again."), style: .error, in: window)
                }
            }
        }
    }

    /// The sheet grows with the interface zoom like the window beneath it, and
    /// is held inside that window so it never hangs over an edge.
    private static func contentSizes(in parent: NSWindow) -> (minimum: NSSize, preferred: NSSize) {
        let scale = MacInterfaceScale.current
        let room = NSSize(
            width: max(parent.frame.width - parentMargin, 320),
            height: max(parent.frame.height - parentMargin, 320)
        )
        func fitted(_ size: NSSize) -> NSSize {
            NSSize(width: min(size.width * scale, room.width), height: min(size.height * scale, room.height))
        }
        return (fitted(minimumContentSize), fitted(baseContentSize))
    }
}
