import FlaccyCore
import Foundation

/// What Flaccy tells a music server about the person's listening: that a song started, that it
/// was listened to, and that it was loved. Reports that cannot be delivered are not lost for stars:
/// the wish is kept and sent when the next sync or star reaches the server.
nonisolated enum RemoteServerReports {

    private static let pendingKey = "flaccy.remote.pendingStars"
    private static let lock = NSLock()

    static func started(_ song: RemoteTrackPath) {
        Task {
            do {
                let client = try await RemoteServers.shared.client(for: song.serverID)
                try await client.scrobble(id: song.songID, at: Date(), submission: false)
            } catch {
                RemoteLog.notice("Could not tell the server a song started: \(error.localizedDescription)")
            }
        }
    }

    static func listened(_ song: RemoteTrackPath, startedAt: Date) {
        Task {
            do {
                let client = try await RemoteServers.shared.client(for: song.serverID)
                try await client.scrobble(id: song.songID, at: startedAt, submission: true)
            } catch {
                RemoteLog.notice("Could not tell the server a song was played: \(error.localizedDescription)")
            }
        }
    }

    /// Stars or unstars a song on its server. A failure keeps the wish for `flushPendingStars`.
    static func setStarred(_ song: RemoteTrackPath, starred: Bool) {
        remember(song.path, starred: starred)
        Task { await flushPendingStars() }
    }

    static func flushPendingStars() async {
        for (path, starred) in pending() {
            guard let song = RemoteTrackPath(path: path) else {
                forget(path)
                continue
            }
            do {
                let client = try await RemoteServers.shared.client(for: song.serverID)
                if starred { try await client.star(id: song.songID) } else { try await client.unstar(id: song.songID) }
                forget(path, ifStill: starred)
            } catch RemoteFailure.songMissing {
                forget(path)
            } catch {
                RemoteLog.notice("Could not \(starred ? "star" : "unstar") a song on its server; will retry: \(error.localizedDescription)")
            }
        }
    }

    static func pending() -> [String: Bool] {
        lock.withLock { UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: Bool] ?? [:] }
    }

    private static func remember(_ path: String, starred: Bool) {
        lock.withLock {
            var all = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: Bool] ?? [:]
            all[path] = starred
            UserDefaults.standard.set(all, forKey: pendingKey)
        }
    }

    private static func forget(_ path: String, ifStill starred: Bool? = nil) {
        lock.withLock {
            var all = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: Bool] ?? [:]
            if let starred, all[path] != starred { return }
            all[path] = nil
            UserDefaults.standard.set(all, forKey: pendingKey)
        }
    }
}
