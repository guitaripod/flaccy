import AVFoundation
import MidgarCore
import FlaccyCore

/// A player item that remembers the `Track.fileURL` it was built for, because the asset behind
/// a song on a server is a cached file or a resource-loader URL, never the track's own URL.
final class TrackPlayerItem: AVPlayerItem {

    let trackURL: URL

    init(asset: AVAsset, trackURL: URL) {
        self.trackURL = trackURL
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)
    }
}

extension AVPlayerItem {

    var sourceTrackURL: URL? { (self as? TrackPlayerItem)?.trackURL }
}

extension PlaybackEngine {

    /// The single place an item is built, so the equalizer can attach its tap to every one.
    /// A song on a server gets its asset from the host, which plays the cached file when it
    /// is complete and streams through a resource loader when it is not.
    func makePlayerItem(for track: Track) -> AVPlayerItem {
        let asset: AVAsset
        if RemoteTrackPath.isRemote(assetURL: track.fileURL), let host {
            asset = host.remoteAsset(for: track)
        } else {
            asset = AVURLAsset(url: track.fileURL)
        }
        let item = TrackPlayerItem(asset: asset, trackURL: track.fileURL)
        host?.attachEqualizer(to: item)
        return item
    }

    func makeConfiguredPlayer(with item: AVPlayerItem) -> AVQueuePlayer {
        let player = AVQueuePlayer(items: [item])
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = sleepAtEndOfTrack ? .pause : .advance
        #if os(macOS)
        player.volume = volume
        #endif
        installTimeControlObservation(on: player)
        installCurrentItemObservation(on: player)
        return player
    }

    /// Single authoritative advance path: every change of the queue player's currentItem
    /// (auto-advance at item end, queue exhaustion, repeat-one restart) flows through here,
    /// with all comparisons done against live player state on the main queue so delayed
    /// delivery can never bind bookkeeping to an already-finished item.
    func installCurrentItemObservation(on player: AVQueuePlayer) {
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleCurrentItemChanged() }
        }
    }

    /// Derives isPlaying from the player's timeControlStatus so system-initiated pauses (route loss, resource contention) keep app and lock-screen state in sync.
    func installTimeControlObservation(on player: AVQueuePlayer) {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            let playing = observedPlayer.timeControlStatus != .paused
            DispatchQueue.main.async {
                guard let self, self.isPlaying != playing else { return }
                self.applyPlaybackState(playing)
            }
        }
    }

    func removePlayerObservers() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    func loadTrack(at index: Int) {
        guard index >= 0, index < queue.count else { return }
        if playbackIsGated() { return }
        currentIndex = index
        userPausedPlayback = false
        pendingQueueExhaustion = false

        removePlayerObservers()

        let track = queue[index]
        let item = makePlayerItem(for: track)

        playingItem = item
        preloadedItem = nil
        preloadedIndex = nil

        if let player {
            player.removeAllItems()
            player.insert(item, after: nil)
        } else {
            player = makeConfiguredPlayer(with: item)
        }

        preloadNextItem(after: index)
        scheduleAutoplayContinuationIfNeeded()

        host?.activateAudioSession()
        player?.play()
        isPlaying = true

        lastKnownPlaybackPosition = 0

        startTimeObserver()

        MidgarLog.info("Load track \(index): \(track.title) - \(track.artist)", category: .playback)
        host?.playbackStateDidUpdate()
        host?.trackDidStart(track)

        postOnMain(PlaybackEngine.trackDidChange)
        postOnMain(PlaybackEngine.playbackStateDidChange)
    }

    /// The queue position the player should be holding ready behind the current
    /// one, honouring repeat-one restarts and repeat-all wrapping.
    func preloadTargetIndex(after index: Int) -> Int? {
        let nextIndex: Int
        if repeatMode == .one {
            nextIndex = index
        } else if index + 1 < queue.count {
            nextIndex = index + 1
        } else if repeatMode == .all && !queue.isEmpty {
            nextIndex = 0
        } else {
            return nil
        }
        return queue.indices.contains(nextIndex) ? nextIndex : nil
    }

    func preloadNextItem(after index: Int) {
        guard let nextIndex = preloadTargetIndex(after: index) else { return }
        let nextItem = makePlayerItem(for: queue[nextIndex])
        if player?.canInsert(nextItem, after: player?.items().last) == true {
            player?.insert(nextItem, after: player?.items().last)
            preloadedItem = nextItem
            preloadedIndex = nextIndex
            MidgarLog.info("Preloaded index \(nextIndex) after \(index)", category: .playback)
        } else {
            MidgarLog.notice("canInsert returned false for track \(nextIndex): \(queue[nextIndex].title)", category: .playback)
        }
    }

    /// True when the item already sitting behind the current one is still the right
    /// one: same queue position, same file, and still the only item queued after it.
    func preloadedItemIsCurrent() -> Bool {
        guard let player, let preloadedItem, let preloadedIndex else { return false }
        guard preloadedIndex == preloadTargetIndex(after: currentIndex) else { return false }
        guard preloadedItem.sourceTrackURL == queue[preloadedIndex].fileURL else { return false }
        let queued = Array(player.items().dropFirst())
        return queued.count == 1 && queued[0] === preloadedItem
    }

    /// Drops every preloaded item after the current one and preloads again, so queue,
    /// shuffle, and repeat mutations can never leave stale audio in the player. A
    /// mutation that leaves the next track unchanged returns early instead: rebuilding
    /// a prerolled item throws away its buffered decoder, and an edit landing near a
    /// track boundary would then hand the transition a cold item and an audible gap.
    func resyncPreloadedItems() {
        guard let player, player.currentItem != nil else { return }
        if preloadedItemIsCurrent() { return }
        for item in player.items().dropFirst() {
            player.remove(item)
        }
        preloadedItem = nil
        preloadedIndex = nil
        preloadNextItem(after: currentIndex)
    }

    func startTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastKnownPlaybackPosition = self.currentTime
                self.host?.playbackDidProgress()
                self.postOnMain(PlaybackEngine.playbackProgressDidChange)
            }
        }
    }

    /// Rebuilds the player around the current queue index and leaves playback paused at the given position; shared by queue restore and media-services recovery.
    func rebuildPlayerPaused(at position: TimeInterval) {
        guard let track = currentTrack else { return }

        removePlayerObservers()

        let item = makePlayerItem(for: track)
        playingItem = item
        preloadedItem = nil
        preloadedIndex = nil
        if let player {
            player.removeAllItems()
            player.insert(item, after: nil)
        } else {
            player = makeConfiguredPlayer(with: item)
        }
        preloadNextItem(after: currentIndex)
        player?.pause()
        isPlaying = false
        userPausedPlayback = true

        if position > 0 {
            let cmTime = CMTime(seconds: position, preferredTimescale: 600)
            player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        startTimeObserver()
        host?.playbackStateDidUpdate()
    }
}
