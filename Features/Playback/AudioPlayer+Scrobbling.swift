import Foundation
import MidgarCore
import FlaccyCore

extension AudioPlayer {

    func checkScrobbleOnSkip() {
        guard !hasScrobbled, let track = currentTrack, track.duration > 0 else { return }
        if meetsScrobbleCriteria(elapsed: currentTime, trackDuration: track.duration) {
            performScrobble()
        }
    }

    func checkScrobbleCriteria() {
        guard !hasScrobbled, let track = currentTrack, track.duration > 0 else { return }
        if meetsScrobbleCriteria(elapsed: currentTime, trackDuration: track.duration) {
            performScrobble()
        }
    }

    func meetsScrobbleCriteria(elapsed: TimeInterval, trackDuration: TimeInterval) -> Bool {
        let threshold = min(240, max(30, trackDuration / 2))
        return elapsed >= threshold
    }

    /// A track that reaches its natural end always counts locally (play count,
    /// Recap stats), but only tracks meeting the Last.fm eligibility rule are
    /// submitted, so sub-30-second interludes are never scrobbled remotely
    /// just because they finished.
    func scrobbleAtNaturalEndIfEligible() {
        guard !hasScrobbled, let track = currentTrack else { return }
        let eligibleForLastFM = track.duration > 0
            && meetsScrobbleCriteria(elapsed: track.duration, trackDuration: track.duration)
        performScrobble(submitToLastFM: eligibleForLastFM)
    }

    /// The sample album is free, bundled-in trial content, not the person's own
    /// library, so a natural-end play of it is not a success worth asking about
    /// (mirrors `PurchaseManager.noteTrackStarted`'s trial-start exclusion).
    func recordReviewSuccessUnlessSample() {
        guard let track = currentTrack, !SampleMusicService.isSample(track.fileURL) else { return }
        ReviewPrompt.recordSuccess()
    }

    /// Write-ahead persists the scrobble, then flushes through the pending
    /// queue as the single Last.fm submission path, so a foreground or
    /// network-restore retry can never double-submit an in-flight scrobble.
    func performScrobble(submitToLastFM: Bool = true) {
        guard let track = currentTrack else { return }
        hasScrobbled = true
        if let song = track.remoteSong { RemoteServerReports.listened(song, startedAt: trackStartTime ?? Date()) }
        Task { @MainActor in
            NotificationCenter.default.post(name: TrialReminderScheduler.optInOpportunity, object: nil)
        }
        let startTime = trackStartTime ?? Date()
        let trackDuration = Int(track.duration)
        let dbID = track.dbID
        let scrobblesToLastFM = submitToLastFM && LastFMService.shared.isAuthenticated
        let record = ScrobbleRecord(
            trackTitle: track.title,
            artist: track.artist,
            albumTitle: track.albumTitle,
            timestamp: startTime,
            duration: trackDuration,
            submitted: !scrobblesToLastFM
        )

        Task { [record, dbID, scrobblesToLastFM] in
            await Task.detached {
                Self.persistScrobble(record, playCountTrackID: dbID)
            }.value
            guard scrobblesToLastFM else { return }
            await self.retryPendingScrobbles()
        }
    }

    /// Bumps the play count and inserts the write-ahead scrobble row off the
    /// main actor so crossing the scrobble threshold never causes a database
    /// hitch mid-playback.
    nonisolated static func persistScrobble(_ record: ScrobbleRecord, playCountTrackID: Int64?) {
        if let playCountTrackID {
            do {
                try DatabaseManager.shared.incrementPlayCount(trackId: playCountTrackID)
            } catch {
                MidgarLog.error("Failed to increment play count: \(error.localizedDescription)", category: .database)
            }
        }
        do {
            try DatabaseManager.shared.insertScrobble(record)
        } catch {
            MidgarLog.error("Failed to persist scrobble: \(error.localizedDescription)", category: .database)
        }
    }

    func sendNowPlayingToLastFM(track: Track) {
        Task {
            await LastFMService.shared.updateNowPlaying(
                track: track.title,
                artist: track.artist,
                album: track.albumTitle,
                duration: Int(track.duration)
            )
        }
    }

    /// Drains the pending queue in passes until it is empty or a pass makes no
    /// progress; a call arriving while a pass is already in flight requests a
    /// fresh drain instead of being dropped, so a row persisted mid-pass is
    /// always picked up. All database work runs off the main actor and only
    /// the gating flags stay on it.
    func retryPendingScrobbles() async {
        #if DEBUG
        if CommandLine.arguments.contains("--memory-audit") || CommandLine.arguments.contains("--skip-keychain") {
            return
        }
        #endif
        guard !isRetryingScrobbles else {
            scrobbleRetryRequested = true
            return
        }
        guard LastFMService.shared.isAuthenticated else { return }
        isRetryingScrobbles = true
        defer { isRetryingScrobbles = false }
        repeat {
            scrobbleRetryRequested = false
            await drainPendingScrobblesOnce()
        } while scrobbleRetryRequested
    }

    func drainPendingScrobblesOnce() async {
        do {
            var pending = try await Task.detached { try Self.retireStaleAndFetchPending() }.value
            while !pending.isEmpty {
                MidgarLog.info("Retrying \(pending.count) pending scrobbles", category: .sync)

                let tuples = pending.compactMap { record -> (id: Int64, track: String, artist: String, album: String, timestamp: Date, duration: Int)? in
                    guard let id = record.id else { return nil }
                    return (id: id, track: record.trackTitle, artist: record.artist, album: record.albumTitle, timestamp: record.timestamp, duration: record.duration)
                }
                let submittedIds = await LastFMService.shared.submitPendingScrobbles(scrobbles: tuples)
                MidgarLog.info("Scrobble retry: \(submittedIds.count)/\(pending.count) submitted", category: .sync)
                guard !submittedIds.isEmpty else { break }

                pending = try await Task.detached { () throws -> [ScrobbleRecord] in
                    try DatabaseManager.shared.markScrobblesSubmitted(ids: submittedIds)
                    return try DatabaseManager.shared.fetchPendingScrobbles()
                }.value
            }
        } catch {
            MidgarLog.error("Scrobble retry failed: \(error.localizedDescription)", category: .sync)
        }
    }

    /// Retires pending scrobbles Last.fm would reject as too old, then returns
    /// the remaining submission backlog; runs off the main actor.
    nonisolated static func retireStaleAndFetchPending() throws -> [ScrobbleRecord] {
        try DatabaseManager.shared.retirePendingScrobbles(
            olderThan: Date().addingTimeInterval(-14 * 86_400)
        )
        return try DatabaseManager.shared.fetchPendingScrobbles()
    }
}
