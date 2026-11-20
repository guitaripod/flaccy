import FlaccyCore
import Foundation

/// The songs one removal took out of a playlist and whether Undo already put
/// them back: the toast's Undo and the undo manager both offer it, and only
/// the first may restore them.
final class PendingRestore {
    let removed: [DatabaseManager.RemovedPlaylistEntry]
    var isDone = false

    init(_ removed: [DatabaseManager.RemovedPlaylistEntry]) {
        self.removed = removed
    }
}
