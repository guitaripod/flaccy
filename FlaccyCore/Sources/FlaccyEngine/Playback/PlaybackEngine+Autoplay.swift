import AVFoundation
import MidgarCore
import FlaccyCore

extension PlaybackEngine {

    /// Extends the queue ahead of exhaustion so the KVO advance path always has a
    /// next item to preload, keeping continuation gapless.
    func scheduleAutoplayContinuationIfNeeded() {
        guard autoplaySimilarWhenQueueEnds, !autoplayContinuationInFlight, repeatMode == .off else { return }
        guard !queue.isEmpty, currentIndex >= queue.count - Self.autoplayContinuationLookahead else { return }
        buildAutoplayContinuation(then: nil)
    }

    func appendContinuation(_ batch: [Track], then completion: ((Bool) -> Void)?) {
        autoplayContinuationInFlight = false
        let existing = Set(queue.map(\.fileURL))
        let fresh = batch.filter { !existing.contains($0.fileURL) }
        guard !fresh.isEmpty else {
            MidgarLog.info("Autoplay continuation produced no new tracks", category: .playback)
            completion?(false)
            resolvePendingExhaustion(appended: false)
            return
        }
        queue.append(contentsOf: fresh)
        originalQueue.append(contentsOf: fresh)
        MidgarLog.info("Autoplay appended \(fresh.count) continuation tracks (queue now \(queue.count))", category: .playback)
        resyncPreloadedItems()
        postOnMain(PlaybackEngine.queueDidChange)
        completion?(true)
        resolvePendingExhaustion(appended: true)
    }

    /// Resumes playback when the queue exhausted while this continuation was
    /// still building: the exhaustion path deferred to us, so a late-arriving
    /// batch starts playing instead of leaving the player silently stopped.
    func resolvePendingExhaustion(appended: Bool) {
        guard pendingQueueExhaustion else { return }
        pendingQueueExhaustion = false
        guard playingItem == nil else { return }
        if appended, queue.indices.contains(currentIndex + 1) {
            MidgarLog.info("Resuming deferred exhaustion with continuation at index \(currentIndex + 1)", category: .playback)
            loadTrack(at: currentIndex + 1)
        } else {
            finishQueueExhausted()
        }
    }

    func buildAutoplayContinuation(then completion: ((Bool) -> Void)?) {
        guard !autoplayContinuationInFlight else { completion?(false); return }
        autoplayContinuationInFlight = true
        let queued = queue
        let request = ContinuationRequest(
            pool: host?.libraryTracks() ?? [],
            queued: queued,
            existing: Set(queued.map(\.fileURL)),
            seedArtist: stationSeedArtist ?? currentTrack?.artist,
            seedTrack: currentTrack
        )
        let builder = continuationBuilder
        Task { [weak self] in
            let batch = await Task.detached { await builder(request) }.value
            self?.appendContinuation(batch, then: completion)
        }
    }
}
