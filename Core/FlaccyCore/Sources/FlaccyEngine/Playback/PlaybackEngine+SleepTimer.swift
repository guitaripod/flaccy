import AVFoundation
import MidgarCore
import FlaccyCore

extension PlaybackEngine {

    public func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        sleepTimerRemaining = TimeInterval(minutes * 60)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let remaining = self.sleepTimerRemaining {
                    self.sleepTimerRemaining = remaining - 1
                    self.postOnMain(PlaybackEngine.sleepTimerDidUpdate)
                    if remaining <= 1 {
                        self.cancelSleepTimer()
                        self.userPausedPlayback = true
                        self.player?.pause()
                        self.applyPlaybackState(false)
                    }
                }
            }
        }
        postOnMain(PlaybackEngine.sleepTimerDidUpdate)
        host?.playFeedback(.light)
    }

    public func setSleepTimerEndOfTrack() {
        cancelSleepTimer()
        sleepAtEndOfTrack = true
        applyActionAtItemEnd()
        postOnMain(PlaybackEngine.sleepTimerDidUpdate)
        host?.playFeedback(.light)
    }

    public func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerRemaining = nil
        sleepAtEndOfTrack = false
        applyActionAtItemEnd()
        postOnMain(PlaybackEngine.sleepTimerDidUpdate)
    }

    /// Holds the queue player on the finished item while a sleep-at-end-of-track
    /// request stands. Pausing after the advance instead would play a moment of the
    /// next song and leave the listener waking up one track further along.
    func applyActionAtItemEnd() {
        player?.actionAtItemEnd = sleepAtEndOfTrack ? .pause : .advance
    }

    /// Completes a sleep-at-end-of-track stop. The next item stays queued and
    /// `actionAtItemEnd` returns to `.advance`, so pressing play resumes on the
    /// following track rather than replaying the one that just finished.
    @objc nonisolated func handleItemDidPlayToEnd(_ notification: Notification) {
        let finishedItem = notification.object as? AVPlayerItem
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sleepAtEndOfTrack else { return }
            guard finishedItem === self.playingItem else { return }
            MidgarLog.info("Sleep at end of track reached, stopping on \(self.currentTrack?.title ?? "unknown")", category: .playback)
            self.cancelSleepTimer()
            self.userPausedPlayback = true
            self.applyPlaybackState(false)
        }
    }
}
