import FlaccyCore
import MidgarCore
import UIKit

/// What the iPhone and iPad can do to a whole playlist, from its row in the
/// library, its page or the iPad sidebar: play it, queue it, rename, copy or
/// delete it. Every command reads the playlist's songs fresh, so a list that
/// was drawn before a sync never plays the wrong ones.
@MainActor
enum PlaylistCommands {

    static func context(id: Int64, name: String) -> PlaybackContext {
        PlaybackContext(kind: .playlist, id: String(id), title: name, subtitle: "")
    }

    /// The playlist's songs the library has, in the playlist's order.
    static func tracks(of id: Int64) -> [Track] {
        ((try? DatabaseManager.shared.fetchPlaylistEntries(playlistId: id)) ?? []).compactMap { entry in
            entry.track.map { Track.from(record: $0, artwork: nil) }
        }
    }

    static func play(id: Int64, name: String, shuffled: Bool) {
        let tracks = tracks(of: id)
        guard !tracks.isEmpty else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        AudioPlayer.shared.play(shuffled ? tracks.shuffled() : tracks, startingAt: 0, context: context(id: id, name: name))
    }

    static func playNext(id: Int64, in view: UIView?) {
        let tracks = tracks(of: id)
        guard !tracks.isEmpty else { return }
        for track in tracks.reversed() { AudioPlayer.shared.insertNext(track) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let view { ToastView.show(String(localized: "Playing next"), in: view, style: .success) }
    }

    static func addToQueue(id: Int64, in view: UIView?) {
        let tracks = tracks(of: id)
        guard !tracks.isEmpty else { return }
        for track in tracks { AudioPlayer.shared.addToQueue(track) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let view { ToastView.show(String(localized: "Added to queue"), in: view, style: .success) }
    }

    static func promptRename(id: Int64, name: String, from host: UIViewController, then: ((String) -> Void)? = nil) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let alert = UIAlertController(title: PlaylistCopy.renameTitle, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = name
            field.placeholder = PlaylistCopy.namePlaceholder
            field.autocapitalizationType = .words
            field.clearButtonMode = .whileEditing
        }
        let rename = UIAlertAction(title: PlaylistCopy.rename, style: .default) { [weak host, weak alert] _ in
            guard let newName = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !newName.isEmpty, newName != name else { return }
            do {
                try DatabaseManager.shared.renamePlaylist(id: id, name: newName)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                NotificationCenter.default.post(name: PlaylistWriter.didChange, object: nil, userInfo: [PlaylistWriter.playlistIDKey: id])
                then?(newName)
            } catch {
                failed(error, name: name, in: host?.view)
            }
        }
        PlaylistWriter.enableWhileNamed(rename, in: alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(rename)
        alert.preferredAction = rename
        host.present(alert, animated: true)
    }

    /// Makes a copy called "Name Copy" (or the next free number) and answers
    /// its id.
    @discardableResult
    static func duplicate(id: Int64, name: String, in view: UIView?) -> PlaylistRecord? {
        let taken = ((try? DatabaseManager.shared.fetchAllPlaylists()) ?? []).map(\.name)
        let copyName = PlaylistEditing.copyName(of: name, copyWord: PlaylistCopy.copyWord, taken: taken)
        do {
            let copy = try DatabaseManager.shared.duplicatePlaylist(id: id, name: copyName)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            NotificationCenter.default.post(name: PlaylistWriter.didChange, object: nil, userInfo: [PlaylistWriter.playlistIDKey: copy.id ?? 0])
            if let copyId = copy.id {
                AlbumArtworkCache.shared.invalidate(keys: [(PlaylistCover.title(forPlaylist: copyId), PlaylistCover.artist)])
            }
            if let view { ToastView.show(PlaylistCopy.duplicated(copyName), in: view, style: .success) }
            return copy
        } catch {
            failed(error, name: name, in: view)
            return nil
        }
    }

    /// Asks before deleting, from `source` on an iPad.
    static func confirmDelete(id: Int64, name: String, from host: UIViewController, source: UIView? = nil, then: (() -> Void)? = nil) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let sheet = UIAlertController(
            title: PlaylistCopy.deleteTitle(name), message: PlaylistCopy.deleteMessage,
            preferredStyle: source == nil ? .alert : .actionSheet
        )
        sheet.addAction(UIAlertAction(title: PlaylistCopy.delete, style: .destructive) { [weak host] _ in
            do {
                try DatabaseManager.shared.deletePlaylist(id: id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                NotificationCenter.default.post(name: PlaylistWriter.didChange, object: nil, userInfo: [PlaylistWriter.playlistIDKey: id])
                MidgarLog.info("Deleted a playlist", category: .database)
                then?()
            } catch {
                failed(error, name: name, in: host?.view)
            }
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        if let source, let popover = sheet.popoverPresentationController {
            popover.sourceView = source
            popover.sourceRect = source.bounds
        }
        host.present(sheet, animated: true)
    }

    /// Play, Shuffle, Play Next and Add to Queue for a whole playlist.
    static func playbackActions(id: Int64, name: String, in view: UIView?) -> [UIMenuElement] {
        [
            UIAction(title: String(localized: "Play"), image: UIImage(systemName: "play.fill")) { _ in
                play(id: id, name: name, shuffled: false)
            },
            UIAction(title: String(localized: "Shuffle"), image: UIImage(systemName: "shuffle")) { _ in
                play(id: id, name: name, shuffled: true)
            },
            UIAction(title: String(localized: "Play Next"), image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { [weak view] _ in
                playNext(id: id, in: view)
            },
            UIAction(title: String(localized: "Add to Queue"), image: UIImage(systemName: "text.append")) { [weak view] _ in
                addToQueue(id: id, in: view)
            },
        ]
    }

    /// Rename, Duplicate and Delete for a whole playlist.
    static func manageActions(
        id: Int64, name: String, from host: UIViewController, source: UIView? = nil,
        renamed: ((String) -> Void)? = nil, deleted: (() -> Void)? = nil
    ) -> [UIMenuElement] {
        [
            UIMenu(options: .displayInline, children: [
                UIAction(title: PlaylistCopy.renameMenu, image: UIImage(systemName: "pencil")) { [weak host] _ in
                    guard let host else { return }
                    promptRename(id: id, name: name, from: host, then: renamed)
                },
                UIAction(title: PlaylistCopy.duplicate, image: UIImage(systemName: "plus.square.on.square")) { [weak host] _ in
                    duplicate(id: id, name: name, in: host?.view)
                },
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(title: PlaylistCopy.deleteMenu, image: UIImage(systemName: "trash"), attributes: .destructive) { [weak host, weak source] _ in
                    guard let host else { return }
                    confirmDelete(id: id, name: name, from: host, source: source, then: deleted)
                },
            ]),
        ]
    }

    private static func failed(_ error: Error, name: String, in view: UIView?) {
        MidgarLog.error("A playlist write failed: \(error.localizedDescription)", category: .database)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        if let view { ToastView.show(PlaylistCopy.writeFailed(name), in: view, style: .error) }
    }
}
