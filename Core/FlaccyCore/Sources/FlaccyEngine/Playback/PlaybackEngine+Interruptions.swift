import AVFoundation
import MidgarCore
import FlaccyCore

extension PlaybackEngine {

    #if os(iOS)
    /// Registers the audio session handlers. The session posts on whichever thread it likes, so every handler is
    /// `nonisolated`: Swift 6 traps a main-actor `@objc` entry the moment it runs elsewhere. Each reads what it needs
    /// from the notification and then hops to the main queue.
    func registerAudioSessionObservers() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMediaServicesReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil
        )
    }

    @objc nonisolated func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                self.wasPlayingBeforeInterruption =
                    self.isPlaying || (self.playingItem != nil && !self.userPausedPlayback)
                if self.isPlaying {
                    self.player?.pause()
                    self.applyPlaybackState(false)
                }
            case .ended:
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
                if self.wasPlayingBeforeInterruption, options.contains(.shouldResume) {
                    self.userPausedPlayback = false
                    self.host?.activateAudioSession()
                    self.player?.play()
                    self.applyPlaybackState(true)
                }
                self.wasPlayingBeforeInterruption = false
            @unknown default:
                break
            }
        }
    }

    @objc nonisolated func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
              reason == .oldDeviceUnavailable
        else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPlaying else { return }
            self.userPausedPlayback = true
            self.player?.pause()
            self.applyPlaybackState(false)
        }
    }

    /// Rebuilds the player after mediaserverd crashes, which invalidates every AVFoundation object the app holds.
    @objc nonisolated func handleMediaServicesReset() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MidgarLog.notice("Media services were reset, rebuilding player", category: .content)
            let resumePosition = self.lastKnownPlaybackPosition
            self.timeControlObservation = nil
            self.currentItemObservation = nil
            self.playingItem = nil
            self.preloadedItem = nil
            self.preloadedIndex = nil
            self.removePlayerObservers()
            self.player = nil
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            guard self.currentTrack != nil else { return }
            self.rebuildPlayerPaused(at: resumePosition)
            postOnMain(PlaybackEngine.playbackStateDidChange)
        }
    }
    #endif

    /// Skips past an item that cannot finish decoding so one corrupt file never stalls the whole queue.
    @objc nonisolated func handleItemFailedToPlayToEnd(_ notification: Notification) {
        let failedItem = notification.object as? AVPlayerItem
        let errorDescription = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "unknown"
        DispatchQueue.main.async { [weak self] in
            guard let self, let failedItem, failedItem === self.playingItem else { return }
            MidgarLog.error("Item failed to play to end at index \(self.currentIndex): \(errorDescription)", category: .playback)
            self.nextTrack()
        }
    }
}
