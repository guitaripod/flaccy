import FlaccyCore
import MidgarCore
import Foundation

/// Takes plays the watch performed on its own and counts them like any other
/// play: the track's play count, a write-ahead scrobble row, and Last.fm when
/// the person is signed in.
enum WatchPlayIngestor {

    private static let seenKey = "watchSync.seenPlayIDs"

    static func ingest(_ entries: [WatchPlayEntry], service: WatchSyncService) {
        guard !entries.isEmpty else { return }
        var ledger = WatchPlayLedger(seenIDs: UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        let fresh = ledger.accept(entries)
        UserDefaults.standard.set(ledger.seenIDs, forKey: seenKey)
        guard !fresh.isEmpty else { return }

        let submitsToLastFM = LastFMService.shared.isAuthenticated
        let counted = fresh.map { entry in
            Counted(
                record: ScrobbleRecord(
                    trackTitle: entry.title,
                    artist: entry.artist,
                    albumTitle: entry.album,
                    timestamp: entry.startedAt,
                    duration: entry.durationSeconds,
                    submitted: !submitsToLastFM
                ),
                trackID: service.track(forStem: SyncStem.of(entry.path))?.dbID
            )
        }
        MidgarLog.info("Counting \(counted.count) plays from the watch", category: .connectivity)
        Task {
            await Task.detached { persist(counted) }.value
            if submitsToLastFM {
                await AudioPlayer.shared.retryPendingScrobbles()
            }
        }
    }

    private struct Counted: Sendable {
        let record: ScrobbleRecord
        let trackID: Int64?
    }

    private nonisolated static func persist(_ counted: [Counted]) {
        for play in counted {
            if let trackID = play.trackID {
                do {
                    try DatabaseManager.shared.incrementPlayCount(trackId: trackID)
                } catch {
                    MidgarLog.error("Watch play count failed: \(error.localizedDescription)", category: .database)
                }
            }
            do {
                try DatabaseManager.shared.insertScrobble(play.record)
            } catch {
                MidgarLog.error("Watch scrobble failed: \(error.localizedDescription)", category: .database)
            }
        }
    }
}
