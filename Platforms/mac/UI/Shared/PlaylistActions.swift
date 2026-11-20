import AppKit
import MidgarCore

extension Notification.Name {
    static let flaccyPlaylistsDidChange = Notification.Name("flaccy.mac.playlistsDidChange")
}

/// Shared playlist mutations behind every "Add to Playlist" surface: the
/// submenu (the playlists last added to first, a check on any that already
/// holds the song), the New Playlist prompt, and additions that leave out
/// songs the playlist already holds and say so.
enum PlaylistActions {

    static func addToPlaylistSubmenu(for tracks: [Track], in window: NSWindow?) -> NSMenu {
        let menu = NSMenu()
        let newItem = ClosureMenuItem(title: String(localized: "New Playlist…")) {
            promptForNewPlaylist(adding: tracks, in: window)
        }
        newItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        menu.addItem(newItem)

        let playlists = PlaylistRecents.ordered((try? DatabaseManager.shared.fetchAllPlaylists()) ?? [])
        if !playlists.isEmpty {
            menu.addItem(.separator())
        }
        let holding = PlaylistRecents.holdingAll(tracks.map { LibraryPathResolver.relativePath(for: $0.fileURL) })
        for playlist in playlists {
            guard let id = playlist.id else { continue }
            let item = ClosureMenuItem(title: playlist.name) {
                add(tracks, toPlaylist: id, named: playlist.name, in: window)
            }
            item.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: nil)
            if holding.contains(id) {
                item.state = .on
                item.toolTip = PlaylistCopy.inPlaylist
            }
            menu.addItem(item)
        }
        return menu
    }

    static func promptForNewPlaylist(adding tracks: [Track], suggestedName: String = "", in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "New Playlist")
        alert.informativeText = tracks.isEmpty
            ? String(localized: "Name your new playlist.")
            : (tracks.count == 1
                ? String(localized: "Name the playlist for this track.")
                : String(localized: "Name the playlist for these \(tracks.count) tracks."))
        alert.addButton(withTitle: String(localized: "Create"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = String(localized: "Playlist name")
        field.stringValue = suggestedName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let respond: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            do {
                let playlist = try DatabaseManager.shared.createPlaylist(
                    name: name, trackFileURLs: tracks.map { LibraryPathResolver.relativePath(for: $0.fileURL) }
                )
                if let id = playlist.id { PlaylistRecents.noteUsed(id) }
                MidgarLog.info("Playlist created with \(tracks.count) songs", category: .database)
                if !tracks.isEmpty { MacToast.show(PlaylistCopy.added(tracks.count, to: name), style: .success, in: window) }
                NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
            } catch {
                MidgarLog.error("Playlist creation failed: \(error.localizedDescription)", category: .database)
                MacToast.show(String(localized: "Couldn't create \u{201C}\(name)\u{201D} — the library database couldn't be written. Check free disk space and try again."), style: .error, in: window)
            }
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    /// Appends the songs the playlist does not hold yet, in one commit, and
    /// says what happened.
    @discardableResult
    static func add(_ tracks: [Track], toPlaylist id: Int64, named name: String, in window: NSWindow?) -> PlaylistEditing.Addition? {
        guard !tracks.isEmpty else { return nil }
        do {
            let addition = try DatabaseManager.shared.addMissingTracksToPlaylist(
                playlistId: id,
                trackFileURLs: tracks.map { LibraryPathResolver.relativePath(for: $0.fileURL) }
            )
            PlaylistRecents.noteUsed(id)
            MidgarLog.info("Added \(addition.added.count) songs to a playlist, \(addition.alreadyIn.count) already there", category: .database)
            let message: String
            switch (addition.added.count, addition.alreadyIn.count) {
            case (0, _): message = PlaylistCopy.alreadyIn(name)
            case (let added, 0): message = PlaylistCopy.added(added, to: name)
            case (let added, let skipped): message = PlaylistCopy.addedSkipping(added, skipped: skipped, to: name)
            }
            MacToast.show(message, style: addition.added.isEmpty ? .info : .success, in: window)
            NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
            return addition
        } catch {
            MidgarLog.error("Add to playlist failed: \(error.localizedDescription)", category: .database)
            MacToast.show(String(localized: "Couldn't add to \u{201C}\(name)\u{201D} — the library database couldn't be written. Check free disk space and try again."), style: .error, in: window)
            return nil
        }
    }

    /// Makes a copy called "Name Copy" (or the next free number).
    static func duplicate(_ playlist: PlaylistRecord, in window: NSWindow?) {
        guard let id = playlist.id else { return }
        let taken = ((try? DatabaseManager.shared.fetchAllPlaylists()) ?? []).map(\.name)
        let name = PlaylistEditing.copyName(of: playlist.name, copyWord: PlaylistCopy.copyWord, taken: taken)
        do {
            try DatabaseManager.shared.duplicatePlaylist(id: id, name: name)
            MacToast.show(PlaylistCopy.duplicated(name), style: .success, in: window)
            NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
        } catch {
            MidgarLog.error("Playlist copy failed: \(error.localizedDescription)", category: .database)
            MacToast.show(PlaylistCopy.writeFailed(playlist.name), style: .error, in: window)
        }
    }
}

/// NSMenuItem that runs a closure, so menu factories don't need a target
/// object to route selectors through.
nonisolated final class ClosureMenuItem: NSMenuItem {

    private let handler: @MainActor () -> Void

    init(title: String, systemImage: String? = nil, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        if let systemImage {
            image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}
