import FlaccyCore
import FlaccyEngine
import Foundation

/// What the screens need to know about remote songs without touching the disk per row: which
/// songs have every byte on this device, which of those the person downloaded, and which servers
/// did not answer the last time they were asked. A song is dimmed when its server cannot be
/// reached and no complete copy of it is here.
nonisolated final class RemoteAvailability: @unchecked Sendable {

    static let shared = RemoteAvailability()

    static let didChange = Notification.Name("RemoteAvailabilityDidChange")
    static let playbackUnavailable = Notification.Name("RemotePlaybackUnavailable")
    static let messageKey = "message"
    private static let announceSpacing: TimeInterval = 10

    private let lock = NSLock()
    private var complete: Set<String> = []
    private var pinned: Set<String> = []
    private var unreachable: Set<String> = []
    private var announcePending = false
    private var lastUnavailableAnnouncement: (path: String, at: Date)?

    func isDownloaded(path: String) -> Bool {
        lock.withLock { pinned.contains(path) && complete.contains(path) }
    }

    func isPinned(path: String) -> Bool {
        lock.withLock { pinned.contains(path) }
    }

    func isComplete(path: String) -> Bool {
        lock.withLock { complete.contains(path) }
    }

    func isUnreachable(serverID: String) -> Bool {
        lock.withLock { unreachable.contains(serverID) }
    }

    /// Whether a song cannot be played right now: its server did not answer and no whole copy is on this device.
    func isUnavailable(_ song: RemoteTrackPath) -> Bool {
        lock.withLock { unreachable.contains(song.serverID) && !complete.contains(song.path) }
    }

    /// Tells the screens that a song the person is playing cannot be fetched: its server did not
    /// answer and no whole copy is here. The same song is announced at most once in ten seconds.
    func announceUnavailable(_ song: RemoteTrackPath) {
        let due = lock.withLock { () -> Bool in
            if let last = lastUnavailableAnnouncement, last.path == song.path, Date().timeIntervalSince(last.at) < Self.announceSpacing {
                return false
            }
            lastUnavailableAnnouncement = (song.path, Date())
            return true
        }
        guard due else { return }
        let title = (try? DatabaseManager.shared.fetchTrack(byRelativePath: song.path))?.title ?? ""
        let server = (try? DatabaseManager.shared.fetchRemoteServer(id: song.serverID))?.name ?? song.serverID
        let message = RemoteCopy.unavailable(title: title, server: server)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.playbackUnavailable, object: nil, userInfo: [Self.messageKey: message])
        }
    }

    /// Reads what the disk and the library rows say, once at launch.
    func load(cachesRoot: URL, pinnedRoot: URL) {
        var found: Set<String> = []
        for root in [cachesRoot, pinnedRoot] { found.formUnion(Self.completePaths(in: root)) }
        let pinnedPaths = Set((try? DatabaseManager.shared.fetchPinnedRemotePaths()) ?? [])
        lock.withLock {
            complete = found
            pinned = pinnedPaths
        }
        announce()
    }

    func setComplete(_ path: String, _ isComplete: Bool) {
        let changed = lock.withLock { isComplete ? complete.insert(path).inserted : complete.remove(path) != nil }
        if changed { announce() }
    }

    func setPinned(_ paths: [String], _ isPinned: Bool) {
        let changed = lock.withLock { () -> Bool in
            var any = false
            for path in paths {
                any = (isPinned ? pinned.insert(path).inserted : pinned.remove(path) != nil) || any
            }
            return any
        }
        if changed { announce() }
    }

    func setReachable(serverID: String, _ reachable: Bool) {
        let changed = lock.withLock { reachable ? unreachable.remove(serverID) != nil : unreachable.insert(serverID).inserted }
        if changed { announce() }
    }

    func forget(paths: [String]) {
        lock.withLock {
            for path in paths {
                complete.remove(path)
                pinned.remove(path)
            }
        }
        announce()
    }

    func forget(serverID: String) {
        let prefix = RemoteTrackPath(serverID: serverID, songID: "x").path.dropLast(1)
        lock.withLock {
            complete = complete.filter { !$0.hasPrefix(prefix) }
            pinned = pinned.filter { !$0.hasPrefix(prefix) }
            unreachable.remove(serverID)
        }
        announce()
    }

    /// Tells the screens once per run-loop turn, however many songs changed in it.
    private func announce() {
        let shouldPost = lock.withLock { () -> Bool in
            if announcePending { return false }
            announcePending = true
            return true
        }
        guard shouldPost else { return }
        DispatchQueue.main.async { [self] in
            lock.withLock { announcePending = false }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    private static func completePaths(in root: URL) -> [String] {
        let manager = FileManager.default
        guard let servers = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var paths: [String] = []
        for server in servers {
            let files = (try? manager.contentsOfDirectory(at: server, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasSuffix(RemoteCacheLayout.sidecarSuffix) {
                guard let data = try? Data(contentsOf: file), let sidecar = try? RemoteCacheSidecar.decode(data),
                      sidecar.isComplete
                else { continue }
                let song = String(file.lastPathComponent.dropLast(RemoteCacheLayout.sidecarSuffix.count))
                paths.append(RemoteTrackPath.scheme + server.lastPathComponent + "/" + song)
            }
        }
        return paths
    }
}

extension Track {

    /// Whether this is a song on a server that the person downloaded and that is whole on this device.
    nonisolated var isDownloadedRemote: Bool {
        guard let song = remoteSong else { return false }
        return RemoteAvailability.shared.isDownloaded(path: song.path)
    }

    /// Whether this song is on a server that cannot be reached and has no whole copy on this device.
    nonisolated var isUnavailableOffline: Bool {
        guard let song = remoteSong else { return false }
        return RemoteAvailability.shared.isUnavailable(song)
    }
}
