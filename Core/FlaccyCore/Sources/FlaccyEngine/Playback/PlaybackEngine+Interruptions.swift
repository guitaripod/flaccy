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
                self.interruptionBegan()
            case .ended:
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
                self.interruptionEnded(shouldResume: options.contains(.shouldResume))
            @unknown default:
                break
            }
        }
    }

    /// Remembers whether music was playing, pauses, and tells the host so it can listen for the other app
    /// going quiet.
    func interruptionBegan() {
        let wasPlaying = isPlaying || (playingItem != nil && !userPausedPlayback)
        if isPlaying {
            player?.pause()
            applyPlaybackState(false)
        }
        wasPlayingBeforeInterruption = wasPlaying
        MidgarLog.info("Interruption began, wasPlaying=\(wasPlaying)", category: .playback)
        if wasPlaying { host?.interruptionDidBegin() }
    }

    /// Plays again when the system hands the sound back and the person's choice allows it. Without a hand-back
    /// the wait goes on only for the choice that listens for quiet.
    func interruptionEnded(shouldResume: Bool) {
        let choice = host?.interruptionResume ?? .whenHandedBack
        MidgarLog.info(
            "Interruption ended, shouldResume=\(shouldResume) awaiting=\(isAwaitingInterruptionEnd) choice=\(choice.rawValue)",
            category: .playback
        )
        if choice.resumes(onHandBack: shouldResume) {
            resumeAfterInterruption()
        }
        if !choice.watchesForQuiet {
            wasPlayingBeforeInterruption = false
        }
    }

    /// Whether music was cut off by another app and nobody has pressed play or pause since.
    public var isAwaitingInterruptionEnd: Bool {
        wasPlayingBeforeInterruption && !isPlaying
    }

    /// Takes the sound back and plays on from where the interruption cut in. Answers false, and keeps
    /// waiting, when the system refuses the session (a call still in progress, for one).
    @discardableResult
    public func resumeAfterInterruption() -> Bool {
        guard isAwaitingInterruptionEnd, let player, player.currentItem != nil else { return false }
        guard host?.activateAudioSession() ?? false else { return false }
        userPausedPlayback = false
        player.play()
        applyPlaybackState(true)
        MidgarLog.info("Resumed after interruption", category: .playback)
        return true
    }

    /// Stops waiting for an interruption to end, leaving the music paused.
    public func abandonInterruptionWait() {
        wasPlayingBeforeInterruption = false
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
            self.recoverPlayingItem(reason: errorDescription)
        }
    }
}
