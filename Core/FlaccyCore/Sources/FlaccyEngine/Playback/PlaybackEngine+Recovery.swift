import AVFoundation
import MidgarCore
import FlaccyCore

/// What the engine does when an item can no longer play. A song that streams from a server fails when the network
/// does, which says nothing about the song, so it is built again from where it stopped a few times before the
/// queue moves on; a file on the device that fails is damaged and is skipped at once.
extension PlaybackEngine {

    func handleItemFailed(_ item: AVPlayerItem, reason: String) {
        if item === playingItem {
            recoverPlayingItem(reason: reason)
        } else if item === preloadedItem {
            recoverPreloadedItem(item, reason: reason)
        }
    }

    func recoverPlayingItem(reason: String) {
        guard let track = currentTrack else { return }
        let streams = RemoteTrackPath.isRemote(assetURL: track.fileURL)
        guard streams, playingItemRecoveries < RemoteFetchRetry.itemRecoveries else {
            MidgarLog.error("Item failed to play to end at index \(currentIndex): \(reason)", category: .playback)
            nextTrack()
            return
        }
        playingItemRecoveries += 1
        let position = lastKnownPlaybackPosition
        MidgarLog.notice(
            "Item at index \(currentIndex) failed (\(reason)); building it again at \(Int(position)) s, attempt \(playingItemRecoveries)",
            category: .playback
        )
        reloadPlayingItem(at: position)
    }

    /// Builds the playing song's item again and carries on from `position`, playing unless the person had paused.
    func reloadPlayingItem(at position: TimeInterval) {
        guard let player, let track = currentTrack else { return }
        removePlayerObservers()
        let item = makePlayerItem(for: track)
        playingItem = item
        preloadedItem = nil
        preloadedIndex = nil
        player.removeAllItems()
        player.insert(item, after: nil)
        applyStallPolicy()
        preloadNextItem(after: currentIndex)
        if position > 0 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if !userPausedPlayback {
            host?.activateAudioSession()
            player.play()
        }
        startTimeObserver()
        host?.playbackStateDidUpdate()
    }

    /// Replaces a preloaded item that failed while it waited, after a pause that grows with each attempt, so the
    /// change of song finds an item that can play.
    func recoverPreloadedItem(_ item: AVPlayerItem, reason: String) {
        guard preloadedItemRecoveries < RemoteFetchRetry.itemRecoveries else {
            MidgarLog.notice("Preloaded item failed again (\(reason)); it is loaded afresh when its turn comes", category: .playback)
            return
        }
        preloadedItemRecoveries += 1
        let attempt = preloadedItemRecoveries
        MidgarLog.notice("Preloaded item failed (\(reason)); preloading it again, attempt \(attempt)", category: .playback)
        DispatchQueue.main.asyncAfter(deadline: .now() + RemoteFetchRetry.preloadDelay(attempt: attempt)) { [weak self] in
            guard let self, let player = self.player, item === self.preloadedItem else { return }
            player.remove(item)
            self.preloadedItem = nil
            self.preloadedIndex = nil
            self.preloadNextItem(after: self.currentIndex)
        }
    }
}
