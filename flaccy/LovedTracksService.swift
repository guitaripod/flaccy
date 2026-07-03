import Foundation

/// Offline-first loved-track state. Toggling writes the local DB and queues a
/// pending love/unlove op immediately; the Last.fm round-trip happens later and
/// is retried until it succeeds. The local `tracks.loved` column is the source
/// of truth for the UI; Last.fm is a mirror.
nonisolated final class LovedTracksService: @unchecked Sendable {

    static let shared = LovedTracksService()

    static let didChange = Notification.Name("LovedTracksServiceDidChange")

    private let db = DatabaseManager.shared
    private let lastFM = LastFMService.shared
    private let lock = NSLock()
    private var lovedPaths: Set<String> = []

    private init() {
        reloadCache()
    }

    private func reloadCache() {
        let paths = (try? db.fetchLovedFileURLs()) ?? []
        lock.lock()
        lovedPaths = paths
        lock.unlock()
    }

    func isLoved(track: Track) -> Bool {
        let path = relativePath(for: track.fileURL)
        lock.lock()
        defer { lock.unlock() }
        return lovedPaths.contains(path)
    }

    @discardableResult
    func toggleLove(track: Track) async -> Bool {
        let path = relativePath(for: track.fileURL)
        let newValue = !isLoved(track: track)

        do {
            try db.setLoved(fileURL: path, loved: newValue, pendingOp: newValue ? "love" : "unlove")
        } catch {
            AppLogger.error("Failed to persist loved state: \(error.localizedDescription)", category: .database)
            return isLoved(track: track)
        }

        lock.lock()
        if newValue { lovedPaths.insert(path) } else { lovedPaths.remove(path) }
        lock.unlock()

        NotificationCenter.default.post(name: Self.didChange, object: nil, userInfo: ["fileURL": path, "loved": newValue])

        await flushPendingLoves()
        return newValue
    }

    func flushPendingLoves() async {
        let pending = (try? db.fetchPendingLoveOps()) ?? []
        guard !pending.isEmpty else { return }
        guard lastFM.isAuthenticated else { return }

        for entry in pending {
            let ok: Bool
            if entry.op == "love" {
                ok = await lastFM.loveTrack(artist: entry.artist, track: entry.title)
            } else {
                ok = await lastFM.unloveTrack(artist: entry.artist, track: entry.title)
            }
            if ok {
                try? db.clearPendingLoveOp(fileURL: entry.fileURL)
            }
        }
    }

    func syncLovedFromLastFM() async {
        guard lastFM.isAuthenticated else { return }

        var remote = Set<String>()
        var page = 1
        var totalPages = 1
        repeat {
            let result = await lastFM.fetchLovedTracks(page: page, limit: 1000)
            for track in result.tracks {
                remote.insert(matchKey(title: track.name, artist: track.artist))
            }
            totalPages = result.totalPages
            page += 1
        } while page <= totalPages && page <= 20

        guard let allTracks = try? db.fetchAllTracks() else { return }
        let pendingPaths = Set(((try? db.fetchPendingLoveOps()) ?? []).map(\.fileURL))

        var toLove: [String] = []
        var toUnlove: [String] = []
        for track in allTracks {
            guard !pendingPaths.contains(track.fileURL) else { continue }
            let desired = remote.contains(matchKey(title: track.title, artist: track.artist))
            if desired && !track.loved { toLove.append(track.fileURL) }
            else if !desired && track.loved { toUnlove.append(track.fileURL) }
        }

        try? db.markLoved(paths: toLove, loved: true)
        try? db.markLoved(paths: toUnlove, loved: false)
        reloadCache()

        if !toLove.isEmpty || !toUnlove.isEmpty {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    private func matchKey(title: String, artist: String) -> String {
        "\(title.lowercased())\u{0}\(artist.lowercased())"
    }

    private func relativePath(for url: URL) -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(docs.path) else { return url.lastPathComponent }
        let relative = String(path.dropFirst(docs.path.count))
        return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
    }
}
