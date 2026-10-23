import Foundation
import MediaPlayer
import FlaccyCore

extension AudioPlayer {

    func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { @Sendable [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.isPlaying else { return }
                self.togglePlayPause()
            }
            return .success
        }

        center.pauseCommand.addTarget { @Sendable [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isPlaying else { return }
                self.togglePlayPause()
            }
            return .success
        }

        center.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in
            DispatchQueue.main.async { self?.togglePlayPause() }
            return .success
        }

        // Next/previous must stay enabled for lock screen + expanded Dynamic
        // Island transport. Skip-interval commands steal those slots on iOS.
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { @Sendable [weak self] _ in
            DispatchQueue.main.async { self?.nextTrack() }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { @Sendable [weak self] _ in
            DispatchQueue.main.async { self?.previousTrack() }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            DispatchQueue.main.async { self?.seek(to: position) }
            return .success
        }

        // iOS system Now Playing (lock screen / Dynamic Island) only shows one
        // side-button pair. Skip intervals replace next/previous there, so they
        // stay off on iOS; macOS and the in-app player still use ±15s.
        #if os(iOS)
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.skipForwardCommand.preferredIntervals = []
        center.skipBackwardCommand.preferredIntervals = []
        #else
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { @Sendable [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            DispatchQueue.main.async {
                guard let self else { return }
                self.seek(to: min(self.duration, self.currentTime + interval))
            }
            return .success
        }
        center.skipBackwardCommand.addTarget { @Sendable [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            DispatchQueue.main.async {
                guard let self else { return }
                self.seek(to: max(0, self.currentTime - interval))
            }
            return .success
        }
        #endif

        center.changeShuffleModeCommand.isEnabled = true
        center.changeShuffleModeCommand.addTarget { @Sendable [weak self] event in
            guard let shuffleEvent = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let wantsShuffle = shuffleEvent.shuffleType != .off
            DispatchQueue.main.async {
                guard let self else { return }
                if wantsShuffle != self.shuffleEnabled { self.toggleShuffle() }
            }
            return .success
        }

        center.changeRepeatModeCommand.isEnabled = true
        center.changeRepeatModeCommand.addTarget { @Sendable [weak self] event in
            guard let repeatEvent = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let repeatType = repeatEvent.repeatType
            DispatchQueue.main.async {
                guard let self else { return }
                let target: RepeatMode = repeatType == .all ? .all : repeatType == .one ? .one : .off
                while self.repeatMode != target { self.cycleRepeatMode() }
            }
            return .success
        }

        center.likeCommand.isEnabled = true
        center.likeCommand.localizedTitle = String(localized: "Love on Last.fm")
        center.likeCommand.localizedShortTitle = String(localized: "Love")
        center.likeCommand.addTarget { @Sendable [weak self] _ in
            onMainActorSync {
                guard let self, let track = self.currentTrack else { return .commandFailed }
                // Flip the system heart immediately so Dynamic Island / lock screen
                // update without waiting for the app to come foreground.
                let next = !LovedTracksService.shared.isLoved(track: track)
                MPRemoteCommandCenter.shared().likeCommand.isActive = next
                Task {
                    let result = await LovedTracksService.shared.toggleLove(track: track)
                    MPRemoteCommandCenter.shared().likeCommand.isActive = result
                    self.syncRemoteCommandState()
                }
                return .success
            }
        }

        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        syncRemoteCommandState()
    }

    /// Keeps the system UI's shuffle/repeat/like toggles and next/previous
    /// availability showing the app's actual state (lock screen, expanded
    /// Dynamic Island, Control Center, CarPlay all read these).
    func syncRemoteCommandState() {
        let center = MPRemoteCommandCenter.shared()
        let hasTrack = currentTrack != nil
        center.nextTrackCommand.isEnabled = hasTrack
        center.previousTrackCommand.isEnabled = hasTrack
        center.changePlaybackPositionCommand.isEnabled = hasTrack
        center.likeCommand.isEnabled = hasTrack
        #if os(iOS)
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        #endif
        center.changeShuffleModeCommand.currentShuffleType = shuffleEnabled ? .items : .off
        center.changeRepeatModeCommand.currentRepeatType =
            repeatMode == .all ? .all : repeatMode == .one ? .one : .off
        if let track = currentTrack {
            center.likeCommand.isActive = LovedTracksService.shared.isLoved(track: track)
        } else {
            center.likeCommand.isActive = false
        }
    }
}
