import FlaccyCore
import MidgarCore
import Foundation
import WatchConnectivity

/// Plays the watch performed that the phone has not yet confirmed.
///
/// Every play is written to disk before anything is sent, and an entry leaves
/// the file only when WatchConnectivity reports its batch delivered, so a play
/// survives a relaunch, a dead radio and a phone that is not around. The phone
/// ignores an id it has already counted, which makes resending harmless.
nonisolated final class WatchPlayLog: @unchecked Sendable {

    static let shared = WatchPlayLog()

    static let capacity = 500
    static let batchSize = 50
    private static let batchKey = "batchId"

    private struct StoredPlay: Codable, Equatable {
        let id: String
        let path: String
        let title: String
        let artist: String
        let album: String
        let startedAt: Date
        let durationSeconds: Int

        init(_ entry: WatchPlayEntry) {
            id = entry.id
            path = entry.path
            title = entry.title
            artist = entry.artist
            album = entry.album
            startedAt = entry.startedAt
            durationSeconds = entry.durationSeconds
        }

        var entry: WatchPlayEntry {
            WatchPlayEntry(
                id: id,
                path: path,
                title: title,
                artist: artist,
                album: album,
                startedAt: startedAt,
                durationSeconds: durationSeconds
            )
        }
    }

    private struct Snapshot: Codable {
        var entries: [StoredPlay] = []
        var batches: [String: [String]] = [:]
    }

    private let queue = DispatchQueue(label: "com.midgarcorp.flaccy.watch.playlog", qos: .utility)
    private let fileURL: URL
    private var snapshot = Snapshot()
    private var isLoaded = false

    init(fileURL: URL = WatchPlayLog.defaultFileURL) {
        self.fileURL = fileURL
    }

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("watch-plays.json")
    }

    var pendingCount: Int {
        queue.sync {
            loadIfNeeded()
            return snapshot.entries.count
        }
    }

    func record(_ entry: WatchPlayEntry) {
        queue.async {
            self.loadIfNeeded()
            guard !self.snapshot.entries.contains(where: { $0.id == entry.id }) else { return }
            self.snapshot.entries.append(StoredPlay(entry))
            self.dropOldestBeyondCapacity()
            self.persist()
            MidgarLog.info("Recorded watch play '\(entry.title)' (\(self.snapshot.entries.count) pending)", category: .connectivity)
            self.sendPending()
        }
    }

    /// Called when the session is up: transfers the phone never took are put
    /// back in line, the ones still travelling are left alone.
    func sessionDidActivate() {
        queue.async {
            self.loadIfNeeded()
            self.releaseBatchesNotInTransit()
            self.sendPending()
        }
    }

    func transferDidFinish(_ transfer: WCSessionUserInfoTransfer, error: Error?) {
        guard let batchID = transfer.userInfo[Self.batchKey] as? String else { return }
        queue.async {
            self.loadIfNeeded()
            if let error {
                MidgarLog.notice("Play batch \(batchID) failed: \(error.localizedDescription)", category: .connectivity)
                self.snapshot.batches[batchID] = nil
                self.persist()
                return
            }
            let delivered = Set(self.snapshot.batches[batchID] ?? [])
            self.snapshot.entries.removeAll { delivered.contains($0.id) }
            self.snapshot.batches[batchID] = nil
            self.persist()
            MidgarLog.info("Play batch \(batchID) delivered (\(delivered.count) plays, \(self.snapshot.entries.count) pending)", category: .connectivity)
            self.sendPending()
        }
    }

    private func dropOldestBeyondCapacity() {
        let overflow = snapshot.entries.count - Self.capacity
        guard overflow > 0 else { return }
        snapshot.entries.removeFirst(overflow)
        let kept = Set(snapshot.entries.map(\.id))
        snapshot.batches = snapshot.batches.compactMapValues { ids in
            let alive = ids.filter { kept.contains($0) }
            return alive.isEmpty ? nil : alive
        }
        MidgarLog.notice("Play log over capacity: dropped \(overflow) oldest", category: .connectivity)
    }

    private var inFlightIDs: Set<String> {
        Set(snapshot.batches.values.joined())
    }

    /// Hands every entry not already travelling to the phone, 50 at a time.
    private func sendPending() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        let travelling = inFlightIDs
        let waiting = snapshot.entries.filter { !travelling.contains($0.id) }
        guard !waiting.isEmpty else { return }

        for start in stride(from: 0, to: waiting.count, by: Self.batchSize) {
            let batch = Array(waiting[start..<min(start + Self.batchSize, waiting.count)])
            let batchID = UUID().uuidString
            snapshot.batches[batchID] = batch.map(\.id)
            session.transferUserInfo([
                SyncKeys.command: SyncKeys.commandPlays,
                SyncKeys.plays: batch.map { $0.entry.dictionary },
                Self.batchKey: batchID,
            ])
            MidgarLog.info("Sent play batch \(batchID): \(batch.count) plays", category: .connectivity)
        }
        persist()
    }

    /// A batch whose transfer is no longer outstanding and was never reported
    /// finished (the app was killed first) has an unknown fate; its entries go
    /// back to waiting, and the phone's id check absorbs any duplicate.
    private func releaseBatchesNotInTransit() {
        guard WCSession.isSupported() else { return }
        let outstanding = Set(WCSession.default.outstandingUserInfoTransfers.compactMap { $0.userInfo[Self.batchKey] as? String })
        let stale = snapshot.batches.keys.filter { !outstanding.contains($0) }
        guard !stale.isEmpty else { return }
        for batchID in stale { snapshot.batches[batchID] = nil }
        persist()
        MidgarLog.info("Released \(stale.count) play batches for resending", category: .connectivity)
    }

    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            MidgarLog.error("Play log unreadable, starting empty: \(error.localizedDescription)", category: .connectivity)
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            MidgarLog.error("Play log write failed: \(error.localizedDescription)", category: .connectivity)
        }
    }
}

/// The player's three-call window onto play detection: tell it when a track
/// starts, where the playhead is, and when the track stops. Judging and
/// storing the play happens here.
@MainActor
final class WatchPlayReporter {

    static let shared = WatchPlayReporter()

    private var tracker = WatchPlayTracker()
    private let log: WatchPlayLog
    private let now: () -> Date

    init(log: WatchPlayLog = .shared, now: @escaping () -> Date = Date.init) {
        self.log = log
        self.now = now
    }

    /// Call for every track that begins, including each pass of a repeated one.
    /// A track still being counted is judged first, so a skip never loses a
    /// play that had already qualified.
    func trackDidStart(_ item: MediaItem) {
        finishCurrent()
        tracker.begin(
            path: item.relativePath,
            title: item.title,
            artist: item.artist,
            album: item.albumTitle,
            duration: item.duration,
            at: now()
        )
    }

    func playbackDidAdvance(elapsed: TimeInterval, isPlaying: Bool) {
        tracker.advance(to: elapsed, isPlaying: isPlaying)
    }

    func trackDidStop() {
        finishCurrent()
    }

    private func finishCurrent() {
        guard let entry = tracker.finish(now: now()) else { return }
        log.record(entry)
    }
}
