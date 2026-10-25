import Foundation
import FlaccyCore

extension PlaybackEngine {

    static let contextDefaultsKey = "flaccy.queue.context"
    static let savedAtDefaultsKey = "flaccy.queue.savedAt"

    /// Where the queue stands for Home's Continue card, or nil with nothing
    /// queued. A live session that has never been saved reads as saved now.
    public var resumePoint: ResumePoint? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return ResumePoint(
            trackIndex: currentIndex,
            elapsed: currentTime,
            durations: queue.map(\.duration),
            savedAt: queueSavedAt ?? Date()
        )
    }

    nonisolated static func derivedContext(for tracks: [Track]) -> PlaybackContext {
        PlaybackContext.derived(from: tracks.map { .init(album: $0.albumTitle, credit: $0.credit) })
    }

    /// An album context follows the queue: adding another album's song turns
    /// it into a plain queue. Named playlists, mixes and radios keep their name.
    func refreshDerivedContext() {
        guard playbackContext.kind == .album || playbackContext.kind == .queue else { return }
        playbackContext = Self.derivedContext(for: queue)
    }

    func saveContext() {
        let now = Date()
        queueSavedAt = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.savedAtDefaultsKey)
        if let data = try? JSONEncoder().encode(playbackContext) {
            UserDefaults.standard.set(data, forKey: Self.contextDefaultsKey)
        }
    }

    static func loadSavedContext() -> (context: PlaybackContext?, savedAt: Date?) {
        let context = UserDefaults.standard.data(forKey: contextDefaultsKey)
            .flatMap { try? JSONDecoder().decode(PlaybackContext.self, from: $0) }
        let seconds = UserDefaults.standard.double(forKey: savedAtDefaultsKey)
        return (context, seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil)
    }

    /// Applied after a restored queue is rebuilt; a queue saved before
    /// contexts existed is named by its contents.
    func applyRestoredContext(_ saved: (context: PlaybackContext?, savedAt: Date?)) {
        guard !queue.isEmpty else { return }
        playbackContext = saved.context ?? Self.derivedContext(for: queue)
        queueSavedAt = saved.savedAt
        postOnMain(PlaybackEngine.queueDidChange)
    }
}
