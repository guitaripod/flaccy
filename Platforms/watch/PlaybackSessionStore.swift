import FlaccyCore
import MidgarCore
import Foundation

/// Keeps the last playback session on disk so the watch can pick up exactly
/// where it stopped. Writes are coalesced and happen off the main thread:
/// a burst of events costs one atomic file replace, and the newest snapshot
/// always wins.
nonisolated final class PlaybackSessionStore: @unchecked Sendable {

    static let shared = PlaybackSessionStore()

    private let fileURL: URL
    private let minimumInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.midgarcorp.flaccy.watch.session", qos: .utility)
    private var latest: WatchPlaybackSnapshot?
    private var lastWrite = Date.distantPast
    private var trailingWritePending = false

    init(fileURL: URL = PlaybackSessionStore.defaultFileURL, minimumInterval: TimeInterval = 1) {
        self.fileURL = fileURL
        self.minimumInterval = minimumInterval
    }

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("playback-session.json")
    }

    func load() -> WatchPlaybackSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(WatchPlaybackSnapshot.self, from: data)
        } catch {
            MidgarLog.notice("Watch session file unreadable: \(error.localizedDescription)", category: .playback)
            return nil
        }
    }

    /// Queues `snapshot` for writing. Calls closer together than the minimum
    /// interval collapse into one trailing write of the newest snapshot, and
    /// `immediately` skips the wait for moments the process may not survive.
    func save(_ snapshot: WatchPlaybackSnapshot, immediately: Bool = false) {
        queue.async { [self] in
            latest = snapshot
            let wait = minimumInterval - Date().timeIntervalSince(lastWrite)
            if immediately || wait <= 0 {
                writeLatest()
            } else if !trailingWritePending {
                trailingWritePending = true
                queue.asyncAfter(deadline: .now() + wait) { [self] in
                    trailingWritePending = false
                    writeLatest()
                }
            }
        }
    }

    private func writeLatest() {
        guard let snapshot = latest else { return }
        latest = nil
        lastWrite = Date()
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            MidgarLog.error("Watch session save failed: \(error.localizedDescription)", category: .playback)
        }
    }
}
