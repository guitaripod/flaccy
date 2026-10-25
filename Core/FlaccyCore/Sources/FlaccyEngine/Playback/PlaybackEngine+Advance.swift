import AVFoundation
import MidgarCore
import FlaccyCore

extension PlaybackEngine {

    func handleCurrentItemChanged() {
        guard let player else { return }
        let item = player.currentItem
        if item === playingItem { return }
        guard let item else {
            handleQueueExhausted()
            return
        }
        if item === preloadedItem, let nextIndex = preloadedIndex {
            completeAutoAdvance(to: nextIndex, item: item)
            return
        }
        if let resolvedIndex = resolveQueueIndex(for: item) {
            MidgarLog.notice("Advance resolved by URL match to index \(resolvedIndex) (preload bookkeeping was stale)", category: .playback)
            completeAutoAdvance(to: resolvedIndex, item: item)
            return
        }
        MidgarLog.notice("Unrecognized current item after advance, reloading index \(currentIndex)", category: .playback)
        loadTrack(at: currentIndex)
    }

    /// Recovers the queue index for an item the preload bookkeeping no longer knows,
    /// e.g. after two back-to-back advances raced a single main-queue hop.
    func resolveQueueIndex(for item: AVPlayerItem) -> Int? {
        guard let url = item.sourceTrackURL ?? (item.asset as? AVURLAsset)?.url, !queue.isEmpty else { return nil }
        let ordered = Array(queue.indices.dropFirst(currentIndex + 1)) + Array(queue.indices.prefix(currentIndex + 1))
        return ordered.first { queue[$0].fileURL == url }
    }

    func completeAutoAdvance(to nextIndex: Int, item: AVPlayerItem) {
        guard queue.indices.contains(nextIndex) else {
            MidgarLog.notice("Auto-advance target index \(nextIndex) out of bounds (queue count \(queue.count))", category: .playback)
            handleQueueExhausted()
            return
        }
        host?.trackDidFinishNaturally()

        let previousIndex = currentIndex
        currentIndex = nextIndex
        playingItem = item
        preloadedItem = nil
        preloadedIndex = nil
        lastKnownPlaybackPosition = 0

        let track = queue[currentIndex]
        MidgarLog.info("Auto-advance \(previousIndex) -> \(currentIndex): \(track.title) - \(track.artist)", category: .playback)

        resyncPreloadedItems()
        scheduleAutoplayContinuationIfNeeded()

        userPausedPlayback = false
        host?.activateAudioSession()
        player?.play()
        isPlaying = true

        host?.playbackStateDidUpdate()
        host?.trackDidStart(track)

        postOnMain(PlaybackEngine.trackDidChange)
        postOnMain(PlaybackEngine.playbackStateDidChange)
    }

    func handleQueueExhausted() {
        guard playingItem != nil else { return }
        host?.trackDidFinishNaturally()
        playingItem = nil
        preloadedItem = nil
        preloadedIndex = nil

        if autoplaySimilarWhenQueueEnds, repeatMode == .off, !sleepAtEndOfTrack {
            if autoplayContinuationInFlight {
                MidgarLog.info("Queue exhausted at index \(currentIndex) with continuation build in flight, deferring", category: .playback)
                pendingQueueExhaustion = true
                return
            }
            MidgarLog.info("Queue exhausted at index \(currentIndex), attempting autoplay continuation", category: .playback)
            buildAutoplayContinuation { [weak self] appended in
                guard let self else { return }
                if appended, self.queue.indices.contains(self.currentIndex + 1) {
                    self.loadTrack(at: self.currentIndex + 1)
                } else {
                    self.finishQueueExhausted()
                }
            }
            return
        }
        finishQueueExhausted()
    }

    func finishQueueExhausted() {
        MidgarLog.info("Queue exhausted at index \(currentIndex), stopping", category: .playback)
        if sleepAtEndOfTrack {
            cancelSleepTimer()
        }
        player?.pause()
        isPlaying = false
        host?.playbackStateDidUpdate()
        postOnMain(PlaybackEngine.playbackStateDidChange)
    }
}
