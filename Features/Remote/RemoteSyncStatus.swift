import Foundation

/// How far a catalog sync has got, for the library's status surface.
nonisolated struct RemoteSyncProgress: Sendable, Equatable {
    let serverID: String
    let serverName: String
    let isFirstSync: Bool
    var songsRead: Int
    var songTotal: Int?

    var fraction: Double? {
        guard let songTotal, songTotal > 0 else { return nil }
        return min(1, Double(songsRead) / Double(songTotal))
    }
}

/// What the screens show about each server's syncing: the sync running now and, for each
/// server, why its last sync failed.
nonisolated final class RemoteSyncStatus: @unchecked Sendable {

    static let shared = RemoteSyncStatus()

    static let didChange = Notification.Name("RemoteSyncStatusDidChange")

    private let lock = NSLock()
    private var running: [String: RemoteSyncProgress] = [:]
    private var failures: [String: String] = [:]

    /// A sync that is running now, or nil while none runs.
    var current: RemoteSyncProgress? {
        lock.withLock { running.values.min { $0.serverName < $1.serverName } }
    }

    func isSyncing(serverID: String) -> Bool {
        lock.withLock { running[serverID] != nil }
    }

    func lastFailure(serverID: String) -> String? {
        lock.withLock { failures[serverID] }
    }

    func begin(serverID: String, name: String, isFirstSync: Bool) {
        lock.withLock {
            running[serverID] = RemoteSyncProgress(
                serverID: serverID, serverName: name, isFirstSync: isFirstSync, songsRead: 0, songTotal: nil
            )
        }
        announce()
    }

    func update(serverID: String, songsRead: Int? = nil, songTotal: Int? = nil) {
        lock.withLock {
            guard var progress = running[serverID] else { return }
            if let songsRead { progress.songsRead = songsRead }
            if let songTotal { progress.songTotal = songTotal }
            running[serverID] = progress
        }
        announce()
    }

    func finish(serverID: String, failure: String?) {
        lock.withLock {
            running[serverID] = nil
            failures[serverID] = failure
        }
        announce()
    }

    func forget(serverID: String) {
        lock.withLock {
            running[serverID] = nil
            failures[serverID] = nil
        }
        announce()
    }

    private func announce() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }
}
