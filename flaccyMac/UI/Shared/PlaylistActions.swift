import AppKit

extension Notification.Name {
    static let flaccyPlaylistsDidChange = Notification.Name("flaccy.mac.playlistsDidChange")
}

/// Shared playlist mutations behind every "Add to Playlist" surface: submenu
/// construction, the New Playlist prompt, and reorder position rewrites that
/// touch only the rows whose position actually changed.
enum PlaylistActions {

    static func addToPlaylistSubmenu(for tracks: [Track], in window: NSWindow?) -> NSMenu {
        let menu = NSMenu()
        let newItem = ClosureMenuItem(title: "New Playlist…") {
            promptForNewPlaylist(adding: tracks, in: window)
        }
        newItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        menu.addItem(newItem)

        let playlists = (try? DatabaseManager.shared.fetchAllPlaylists()) ?? []
        if !playlists.isEmpty {
            menu.addItem(.separator())
        }
        for playlist in playlists {
            guard let id = playlist.id else { continue }
            let item = ClosureMenuItem(title: playlist.name) {
                add(tracks, toPlaylist: id, named: playlist.name, in: window)
            }
            item.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    static func promptForNewPlaylist(adding tracks: [Track], in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "New Playlist"
        alert.informativeText = tracks.isEmpty
            ? "Name your new playlist."
            : "Name the playlist for \(tracks.count == 1 ? "this track" : "these \(tracks.count) tracks")."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Playlist name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let respond: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            do {
                let playlist = try DatabaseManager.shared.createPlaylist(name: name)
                AppLogger.info("Playlist created: \(name)", category: .database)
                if let id = playlist.id, !tracks.isEmpty {
                    add(tracks, toPlaylist: id, named: name, in: window)
                } else {
                    NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
                }
            } catch {
                AppLogger.error("Playlist creation failed: \(error.localizedDescription)", category: .database)
                MacToast.show("Couldn't create playlist.", style: .error, in: window)
            }
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    static func add(_ tracks: [Track], toPlaylist id: Int64, named name: String, in window: NSWindow?) {
        do {
            for track in tracks {
                try DatabaseManager.shared.addTrackToPlaylist(
                    playlistId: id,
                    trackFileURL: LibraryPathResolver.relativePath(for: track.fileURL)
                )
            }
            AppLogger.info("Added \(tracks.count) track(s) to playlist \(name)", category: .database)
            MacToast.show(
                tracks.count == 1 ? "Added to \(name)" : "Added \(tracks.count) songs to \(name)",
                style: .success, in: window
            )
            NotificationCenter.default.post(name: .flaccyPlaylistsDidChange, object: nil)
        } catch {
            AppLogger.error("Add to playlist failed: \(error.localizedDescription)", category: .database)
            MacToast.show("Couldn't add to playlist.", style: .error, in: window)
        }
    }

    /// Rewrites playlist positions to match the given row order, updating only
    /// the records whose position changed so an adjacent drag touches a
    /// handful of rows instead of the whole playlist.
    static func persistOrder(_ orderedRecords: [PlaylistTrackRecord]) {
        var writes = 0
        for (position, record) in orderedRecords.enumerated() {
            guard record.position != position, let id = record.id else { continue }
            do {
                try DatabaseManager.shared.reorderPlaylistTrack(id: id, newPosition: position)
                writes += 1
            } catch {
                AppLogger.error("Playlist reorder write failed: \(error.localizedDescription)", category: .database)
            }
        }
        AppLogger.info("Playlist reorder persisted (\(writes) position writes)", category: .database)
    }
}

/// NSMenuItem that runs a closure, so menu factories don't need a target
/// object to route selectors through.
final class ClosureMenuItem: NSMenuItem {

    private let handler: () -> Void

    init(title: String, systemImage: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        if let systemImage {
            image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() {
        handler()
    }
}
