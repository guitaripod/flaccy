import FlaccyCore
import MidgarCore
import UIKit

/// Every way the iPhone and iPad put songs into a playlist goes through here:
/// the Add to Playlist menu, a drop on a playlist, the Add Songs sheet, a
/// suggestion, a new playlist made around a song. Songs the playlist already
/// holds are skipped and the toast says so, each write is one commit, and the
/// playlist last added to comes first in the menu next time.
@MainActor
enum PlaylistWriter {

    static let didChange = Notification.Name("flaccy.playlistWriter.didChange")
    static let playlistIDKey = "playlistID"

    @discardableResult
    static func add(_ tracks: [Track], toPlaylist id: Int64, named name: String, in view: UIView?) -> PlaylistEditing.Addition? {
        guard !tracks.isEmpty else { return nil }
        do {
            let addition = try DatabaseManager.shared.addMissingTracksToPlaylist(
                playlistId: id, trackFileURLs: tracks.map(TrackContextMenu.relativePath(for:))
            )
            PlaylistRecents.noteUsed(id)
            NotificationCenter.default.post(name: didChange, object: nil, userInfo: [playlistIDKey: id])
            report(addition, to: name, in: view)
            MidgarLog.info("Added \(addition.added.count) songs to a playlist, \(addition.alreadyIn.count) already there", category: .ui)
            return addition
        } catch {
            fail(error, name: name, in: view)
            return nil
        }
    }

    /// Makes a playlist holding `tracks` in one commit.
    @discardableResult
    static func create(named name: String, with tracks: [Track], in view: UIView?) -> PlaylistRecord? {
        do {
            let playlist = try DatabaseManager.shared.createPlaylist(
                name: name, trackFileURLs: tracks.map(TrackContextMenu.relativePath(for:))
            )
            if let id = playlist.id { PlaylistRecents.noteUsed(id) }
            NotificationCenter.default.post(name: didChange, object: nil, userInfo: [playlistIDKey: playlist.id ?? 0])
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if let view {
                let message = tracks.isEmpty ? String(localized: "Made \u{201C}\(name)\u{201D}") : PlaylistCopy.added(tracks.count, to: name)
                ToastView.show(message, in: view, style: .success)
            }
            return playlist
        } catch {
            MidgarLog.error("Failed to create playlist: \(error.localizedDescription)", category: .database)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            if let view {
                ToastView.show(
                    String(localized: "Couldn't create \u{201C}\(name)\u{201D} — the library database couldn't be written. Check free disk space and try again."),
                    in: view, style: .error
                )
            }
            return nil
        }
    }

    /// Asks for a name and makes a playlist holding `tracks`.
    static func promptNew(with tracks: [Track], from host: UIViewController, suggestedName: String? = nil, then: ((PlaylistRecord) -> Void)? = nil) {
        let alert = UIAlertController(title: String(localized: "New Playlist"), message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = PlaylistCopy.namePlaceholder
            field.autocapitalizationType = .words
            field.text = suggestedName
            field.clearButtonMode = .whileEditing
        }
        let create = UIAlertAction(title: String(localized: "Create"), style: .default) { [weak host, weak alert] _ in
            guard let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { return }
            if let playlist = create(named: name, with: tracks, in: host?.view) { then?(playlist) }
        }
        enableWhileNamed(create, in: alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(create)
        alert.preferredAction = create
        host.present(alert, animated: true)
    }

    /// The Add to Playlist submenu for `tracks`: New Playlist first, then
    /// the playlists last added to, then the rest newest first. A playlist
    /// that already holds every one of the songs wears a check and says so.
    static func addMenu(for tracks: @escaping @MainActor () -> [Track], in host: UIViewController?) -> UIMenu {
        UIMenu(
            title: String(localized: "Add to Playlist"),
            image: UIImage(systemName: "text.badge.plus"),
            children: [UIDeferredMenuElement.uncached { [weak host] completion in
                completion(addActions(for: tracks(), in: host))
            }]
        )
    }

    private static func addActions(for tracks: [Track], in host: UIViewController?) -> [UIMenuElement] {
        let newPlaylist = UIAction(title: String(localized: "New Playlist\u{2026}"), image: UIImage(systemName: "plus")) { [weak host] _ in
            guard let host else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            promptNew(with: tracks, from: host)
        }
        let playlists = PlaylistRecents.ordered((try? DatabaseManager.shared.fetchAllPlaylists()) ?? [])
        let holding = PlaylistRecents.holdingAll(tracks.map(TrackContextMenu.relativePath(for:)))
        let choices: [UIMenuElement] = playlists.compactMap { playlist in
            guard let id = playlist.id else { return nil }
            let holds = holding.contains(id)
            let action = UIAction(
                title: playlist.name, image: UIImage(systemName: holds ? "checkmark.circle" : "music.note.list")
            ) { [weak host] _ in
                add(tracks, toPlaylist: id, named: playlist.name, in: host?.view)
            }
            if holds { action.subtitle = PlaylistCopy.inPlaylist }
            return action
        }
        return [UIMenu(options: .displayInline, children: [newPlaylist])] + choices
    }

    /// Turns `action` on only while the alert's first field holds a name.
    static func enableWhileNamed(_ action: UIAlertAction, in alert: UIAlertController) {
        guard let field = alert.textFields?.first else { return }
        action.isEnabled = isNamed(field)
        field.addAction(UIAction { [weak action, weak field] _ in
            guard let field else { return }
            action?.isEnabled = isNamed(field)
        }, for: .editingChanged)
    }

    private static func isNamed(_ field: UITextField) -> Bool {
        !(field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func report(_ addition: PlaylistEditing.Addition, to name: String, in view: UIView?) {
        let added = addition.added.count
        let skipped = addition.alreadyIn.count
        if added == 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        guard let view else { return }
        let message: String
        switch (added, skipped) {
        case (0, _): message = PlaylistCopy.alreadyIn(name)
        case (_, 0): message = PlaylistCopy.added(added, to: name)
        default: message = PlaylistCopy.addedSkipping(added, skipped: skipped, to: name)
        }
        ToastView.show(message, in: view, style: added == 0 ? .info : .success)
    }

    private static func fail(_ error: Error, name: String, in view: UIView?) {
        MidgarLog.error("Adding songs to a playlist failed: \(error.localizedDescription)", category: .database)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        if let view {
            ToastView.show(
                String(localized: "Couldn't add to \u{201C}\(name)\u{201D} — the library database couldn't be written. Check free disk space and try again."),
                in: view, style: .error
            )
        }
    }
}
