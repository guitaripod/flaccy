import FlaccyCore
import MidgarCore
import UIKit

/// The part of the player a drop into Up Next edits.
protocol UpNextEditing: AnyObject {
    var queue: [Track] { get }
    var currentIndex: Int { get }
    var currentTrack: Track? { get }
    func insertNext(_ track: Track)
    func addToQueue(_ track: Track)
    func moveInQueue(from sourceIndex: Int, to destinationIndex: Int)
}

/// Up Next on the app's own player.
private final class SharedUpNext: UpNextEditing {
    private var player: AudioPlaying { AudioPlayer.shared }
    var queue: [Track] { player.queue }
    var currentIndex: Int { player.currentIndex }
    var currentTrack: Track? { player.currentTrack }
    func insertNext(_ track: Track) { player.insertNext(track) }
    func addToQueue(_ track: Track) { player.addToQueue(track) }
    func moveInQueue(from sourceIndex: Int, to destinationIndex: Int) { player.moveInQueue(from: sourceIndex, to: destinationIndex) }
}

/// Songs carried by a drag that starts in Flaccy.
final class TrackDragPayload: NSObject {
    let tracks: [Track]

    init(tracks: [Track]) {
        self.tracks = tracks
    }
}

/// Dragging songs around an iPad: out of the Library, an album or a playlist,
/// into Up Next, onto a playlist in the sidebar or into a playlist's own list.
/// Inside Flaccy a drop reads the songs themselves; a single song on this
/// device also travels as its audio file, so Files or Mail receive a copy. A
/// song on a server never leaves Flaccy this way.
enum TrackDrag {

    static func items(for tracks: [Track], named name: String) -> [UIDragItem] {
        guard !tracks.isEmpty else { return [] }
        let provider = fileProvider(for: tracks) ?? NSItemProvider()
        provider.suggestedName = name
        let item = UIDragItem(itemProvider: provider)
        item.localObject = TrackDragPayload(tracks: tracks)
        return [item]
    }

    private static func fileProvider(for tracks: [Track]) -> NSItemProvider? {
        guard tracks.count == 1, let track = tracks.first, track.remoteSong == nil,
              FileManager.default.fileExists(atPath: track.fileURL.path) else { return nil }
        return NSItemProvider(contentsOf: track.fileURL)
    }

    static func tracks(in session: UIDropSession) -> [Track] {
        (session.localDragSession?.items ?? []).flatMap { ($0.localObject as? TrackDragPayload)?.tracks ?? [] }
    }

    static func carriesTracks(_ session: UIDropSession) -> Bool {
        session.localDragSession?.items.contains { $0.localObject is TrackDragPayload } == true
    }

    /// Puts songs into Up Next after the first `position` songs already
    /// waiting there, in the order they were dragged.
    static func insertInUpNext(_ tracks: [Track], at position: Int, in player: UpNextEditing = SharedUpNext()) {
        let waiting = player.currentTrack == nil ? player.queue.count : max(player.queue.count - player.currentIndex - 1, 0)
        let position = min(max(position, 0), waiting)
        guard player.currentTrack != nil, position < waiting else {
            tracks.forEach { player.addToQueue($0) }
            return
        }
        tracks.reversed().forEach { player.insertNext($0) }
        let start = player.currentIndex + 1
        for offset in 0..<position {
            player.moveInQueue(from: start + tracks.count + offset, to: start + offset)
        }
    }

    /// Adds songs to the end of a playlist and says so in `view`, leaving
    /// out any the playlist already holds.
    static func add(_ tracks: [Track], toPlaylist id: Int64, named name: String, in view: UIView?) {
        PlaylistWriter.add(tracks, toPlaylist: id, named: name, in: view)
    }
}
