import AVFoundation
import MidgarCore
import FlaccyCore
import MediaPlayer
import Observation
import UIKit
import WatchKit

@MainActor
@Observable
final class WatchAudioPlayer: AudioPlaybackEngine {

    private(set) var playbackQueue = PlaybackQueue()
    private(set) var isPlaying: Bool = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var currentTime: TimeInterval = 0
    private(set) var pendingResumePosition: TimeInterval?

    var volume: Double = 0.7 {
        didSet { player?.volume = Float(volume) }
    }

    @ObservationIgnored private let documentsDirectory: URL
    @ObservationIgnored private var player: AVQueuePlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failedToEndObserver: NSObjectProtocol?
    @ObservationIgnored private var sessionObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var statusObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var cachedArtwork: (trackID: String, artwork: MPMediaItemArtwork)?
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var playIntentGeneration = 0
    @ObservationIgnored private var isActivationPending = false
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var advanceToken = 0
    @ObservationIgnored private var lastSessionSave = Date.distantPast
    @ObservationIgnored private let sessionStore: PlaybackSessionStore

    private static let sessionSaveInterval: TimeInterval = 15
    private static let advanceGraceAttempts = 10
    private static let advanceGraceInterval: Duration = .milliseconds(50)

    init(documentsDirectory: URL, sessionStore: PlaybackSessionStore = .shared) {
        self.documentsDirectory = documentsDirectory
        self.sessionStore = sessionStore
        configureSession()
        configureRemoteCommands()
        observeAudioSession()
    }

    var queue: [MediaItem] { playbackQueue.items }
    var currentIndex: Int { playbackQueue.currentIndex }
    var shuffleEnabled: Bool { playbackQueue.isShuffled }
    var currentItem: MediaItem? { playbackQueue.current }

    /// Everything that will play after the current track, in play order.
    var upNext: [MediaItem] { playbackQueue.upNext }

    var duration: TimeInterval {
        guard let item = player?.currentItem else { return currentItem?.duration ?? 0 }
        let value = CMTimeGetSeconds(item.duration)
        if value.isNaN || value <= 0 { return currentItem?.duration ?? 0 }
        return value
    }

    func play(_ items: [MediaItem], startingAt index: Int) {
        guard !items.isEmpty, items.indices.contains(index) else { return }
        playbackQueue = PlaybackQueue(items: items, startingAt: index, shuffled: shuffleEnabled)
        pendingResumePosition = nil
        WKInterfaceDevice.current().play(.click)
        loadTrack(at: currentIndex)
    }

    func togglePlayPause() {
        if !isPlaying, player?.items().isEmpty != false {
            guard !playbackQueue.isEmpty else { return }
            WKInterfaceDevice.current().play(.click)
            loadTrack(at: currentIndex, startingAt: pendingResumePosition ?? 0)
            return
        }
        guard let player else { return }
        if isActivationPending {
            cancelPendingPlayIntent()
            player.pause()
        } else if isPlaying {
            player.pause()
        } else {
            activateSessionAndPlay()
        }
        WKInterfaceDevice.current().play(.click)
    }

    /// An explicit skip always advances — repeat-one governs only automatic
    /// end-of-track behavior in `handleTrackFinished`.
    func next() {
        guard !playbackQueue.isEmpty else { return }
        if playbackQueue.hasNext {
            playbackQueue.jump(to: currentIndex + 1)
            loadTrack(at: currentIndex)
        } else if repeatMode == .all {
            playbackQueue.jump(to: 0)
            loadTrack(at: currentIndex)
        } else {
            stopPlayback()
        }
    }

    func previous() {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard currentIndex > 0 else {
            seek(to: 0)
            return
        }
        playbackQueue.jump(to: currentIndex - 1)
        loadTrack(at: currentIndex)
    }

    func seek(to time: TimeInterval) {
        let target = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.currentTime = time
                self?.updateNowPlayingInfo()
                if self?.isPlaying == false { self?.persistSession() }
            }
        }
    }

    func toggleShuffle() {
        WKInterfaceDevice.current().play(.click)
        if playbackQueue.isShuffled {
            playbackQueue.unshuffle()
        } else {
            playbackQueue.shuffle(keepingCurrent: true)
        }
        resyncPreloadedItems()
        persistSession()
    }

    func cycleRepeatMode() {
        repeatMode = repeatMode.next
        WKInterfaceDevice.current().play(.click)
        resyncPreloadedItems()
        persistSession()
    }

    /// Drops every preloaded item after the current one and preloads again, so
    /// shuffle and repeat mutations can never leave stale audio queued in the
    /// player behind a UI that shows a different upcoming track.
    private func resyncPreloadedItems() {
        guard let player, player.currentItem != nil else { return }
        for item in player.items().dropFirst() {
            statusObservations.removeValue(forKey: ObjectIdentifier(item))
            player.remove(item)
        }
        preloadNextItem(after: currentIndex)
    }

    func jumpTo(index: Int) {
        guard playbackQueue.jump(to: index) else { return }
        loadTrack(at: index)
    }

    /// Puts `items` directly after the current track. With nothing loaded yet
    /// they simply start playing.
    func playNext(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }
        guard currentItem != nil else {
            play(items, startingAt: 0)
            return
        }
        playbackQueue.playNext(items)
        queueDidChange(feedback: .success)
    }

    /// Appends `items` to the end of the queue. With nothing loaded yet they
    /// simply start playing.
    func enqueue(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }
        guard currentItem != nil else {
            play(items, startingAt: 0)
            return
        }
        playbackQueue.enqueue(items)
        queueDidChange(feedback: .success)
    }

    /// Removes the row at absolute queue index `index`; the playing track is
    /// never removable.
    func removeFromQueue(at index: Int) {
        guard playbackQueue.remove(at: index) else { return }
        queueDidChange(feedback: .click)
    }

    func clearUpNext() {
        guard playbackQueue.hasNext else { return }
        playbackQueue.clearUpNext()
        queueDidChange(feedback: .click)
    }

    /// Every queue edit must also correct what AVQueuePlayer has already
    /// preloaded behind the current item, or the next track heard would not
    /// be the next track listed.
    private func queueDidChange(feedback: WKHapticType) {
        WKInterfaceDevice.current().play(feedback)
        resyncPreloadedItems()
        persistSession()
    }

    private func loadTrack(at index: Int, startingAt position: TimeInterval = 0) {
        guard let track = playbackQueue.item(at: index) else { return }
        advanceToken += 1
        removeObservers()
        pendingResumePosition = nil

        let item = AVPlayerItem(url: track.fileURL(in: documentsDirectory))
        observeStatus(of: item)

        if let player {
            player.removeAllItems()
            player.insert(item, after: nil)
        } else {
            player = makeConfiguredPlayer(with: item)
        }
        player?.volume = Float(volume)

        preloadNextItem(after: index)
        currentTime = position

        addTimeObserver()
        observeEnd(of: item)
        if position > 0 { seek(to: position) }
        updateNowPlayingInfo()
        activateSessionAndPlay()
        persistSession()
        WatchPlayReporter.shared.trackDidStart(track)
        MidgarLog.info("Watch now playing: \(track.title) — \(track.artist)", category: .playback)
    }

    private func handleTrackFinished() {
        removeEndObserver()

        if repeatMode == .one {
            loadTrack(at: currentIndex)
            return
        }

        if playbackQueue.hasNext {
            playbackQueue.jump(to: currentIndex + 1)
            adoptAdvancedItemOrReload()
        } else if repeatMode == .all, !playbackQueue.isEmpty {
            playbackQueue.jump(to: 0)
            loadTrack(at: currentIndex)
        } else {
            stopPlayback()
        }
    }

    /// AVQueuePlayer advances to the preloaded item by itself, and the
    /// end-of-track notification can arrive a beat before it has. Rebuilding at
    /// once would restart a track the player is already starting, so the
    /// advance gets a short grace period to show up before falling back to a
    /// deterministic `loadTrack`. Any newer load, stop or interruption bumps
    /// `advanceToken` and retires this wait.
    private func adoptAdvancedItemOrReload() {
        advanceToken += 1
        if let item = verifiedCurrentPlayerItem() {
            completeGaplessAdvance(to: item)
            return
        }
        let token = advanceToken
        Task { @MainActor [weak self] in
            for _ in 0..<Self.advanceGraceAttempts {
                try? await Task.sleep(for: Self.advanceGraceInterval)
                guard let self, token == self.advanceToken else { return }
                if let item = self.verifiedCurrentPlayerItem() {
                    self.completeGaplessAdvance(to: item)
                    return
                }
            }
            guard let self, token == self.advanceToken else { return }
            self.loadTrack(at: self.currentIndex)
        }
    }

    private func completeGaplessAdvance(to item: AVPlayerItem) {
        currentTime = 0
        observeEnd(of: item)
        preloadNextItem(after: currentIndex)
        activateSessionAndPlay()
        updateNowPlayingInfo()
        persistSession()
        if let current = currentItem { WatchPlayReporter.shared.trackDidStart(current) }
        MidgarLog.info("Watch gapless advance: \(currentItem?.title ?? "")", category: .playback)
    }

    /// The end-of-track notification races AVQueuePlayer's `.advance`
    /// transition, so `currentItem` may still be the just-finished item; only
    /// trust it when its URL matches the track the bookkeeping expects,
    /// otherwise the caller must rebuild deterministically via `loadTrack`.
    private func verifiedCurrentPlayerItem() -> AVPlayerItem? {
        guard let item = player?.currentItem,
              let url = (item.asset as? AVURLAsset)?.url,
              let expected = currentItem?.fileURL(in: documentsDirectory),
              url == expected
        else { return nil }
        return item
    }

    private func preloadNextItem(after index: Int) {
        let nextIndex: Int
        if index + 1 < playbackQueue.count {
            nextIndex = index + 1
        } else if repeatMode == .all, !playbackQueue.isEmpty {
            nextIndex = 0
        } else {
            return
        }
        guard let nextTrack = playbackQueue.item(at: nextIndex) else { return }
        let nextItem = AVPlayerItem(url: nextTrack.fileURL(in: documentsDirectory))
        if player?.canInsert(nextItem, after: player?.items().last) == true {
            observeStatus(of: nextItem)
            player?.insert(nextItem, after: player?.items().last)
        }
    }

    private func observeStatus(of item: AVPlayerItem) {
        statusObservations[ObjectIdentifier(item)] = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status != .unknown else { return }
            Task { @MainActor in
                if item.status == .failed {
                    self?.handleItemFailed(item)
                } else {
                    self?.consecutiveFailures = 0
                }
            }
        }
    }

    /// A missing or corrupt file must never leave the player stuck in a fake
    /// "playing" state: drop the failed item, skip forward, and stop entirely
    /// once every queued track has failed in a row.
    private func handleItemFailed(_ item: AVPlayerItem) {
        MidgarLog.error(
            "Watch player item failed: \(item.error?.localizedDescription ?? "unknown error")",
            category: .playback
        )
        statusObservations.removeValue(forKey: ObjectIdentifier(item))
        guard let player else { return }
        let wasCurrent = player.currentItem === item
        player.remove(item)
        guard wasCurrent else { return }
        consecutiveFailures += 1
        if consecutiveFailures >= max(playbackQueue.count, 1) {
            consecutiveFailures = 0
            stopPlayback()
            return
        }
        next()
    }

    private func stopPlayback() {
        cancelPendingPlayIntent()
        player?.pause()
        WatchPlayReporter.shared.trackDidStop()
        updateNowPlayingInfo()
        persistSession()
    }

    /// Invalidates any activation completion still in flight so a stale play
    /// intent can never restart audio after the user or the system stopped it.
    private func cancelPendingPlayIntent() {
        playIntentGeneration += 1
        advanceToken += 1
        isActivationPending = false
    }

    private func makeConfiguredPlayer(with item: AVPlayerItem) -> AVQueuePlayer {
        let player = AVQueuePlayer(items: [item])
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .advance
        installTimeControlObservation(on: player)
        return player
    }

    /// Derives `isPlaying` from the player's `timeControlStatus` so
    /// system-initiated pauses (interruptions, Bluetooth route loss, resource
    /// contention) keep the UI and now-playing state in sync with reality.
    private func installTimeControlObservation(on player: AVQueuePlayer) {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            let playing = observedPlayer.timeControlStatus != .paused
            Task { @MainActor in
                guard let self, self.isPlaying != playing else { return }
                self.isPlaying = playing
                self.updateNowPlayingInfo()
                if !playing { self.persistSession() }
            }
        }
    }

    var hasRestorableSession: Bool {
        pendingResumePosition != nil && currentItem != nil
    }

    /// What the Library's "Continue" card shows; nil once playback has started
    /// from anywhere or when there is no restored session.
    var resumeSummary: (title: String, artist: String, albumTitle: String, artworkData: Data?)? {
        guard hasRestorableSession, let item = currentItem else { return nil }
        return (item.title, item.artist, item.albumTitle, item.artworkData)
    }

    /// Rebuilds the saved queue paused at the saved position. The audio
    /// session stays untouched and no AVPlayer exists until the first play,
    /// which loads the track, seeks to the position and starts. Ignored when
    /// something is already loaded, so a track started before the library
    /// finished scanning is never replaced.
    func restore(from snapshot: WatchPlaybackSnapshot, in library: [MediaItem]) {
        guard currentItem == nil, let resolved = snapshot.resolve(in: library) else { return }
        playbackQueue = resolved.queue
        repeatMode = snapshot.repeatMode
        volume = min(1, max(0, snapshot.volume))
        currentTime = resolved.position
        pendingResumePosition = resolved.position
        updateNowPlayingInfo()
        MidgarLog.info(
            "Watch session restored: \(resolved.queue.current?.title ?? "") at \(Int(resolved.position))s",
            category: .playback
        )
    }

    /// Continues a restored session from where it stopped.
    func resumePlayback() {
        guard hasRestorableSession else { return }
        togglePlayPause()
    }

    /// Writes the session to disk. Called for track changes, pauses, queue
    /// edits and the background transition (`immediately`); the store throttles
    /// and writes off the main thread.
    func persistSession(immediately: Bool = false) {
        guard currentItem != nil else { return }
        lastSessionSave = Date()
        sessionStore.save(
            WatchPlaybackSnapshot(
                queue: playbackQueue,
                position: currentTime,
                repeatMode: repeatMode,
                volume: volume
            ),
            immediately: immediately
        )
    }

    /// The periodic playback tick calls this, so a long track still leaves a
    /// position no more than a quarter minute stale if the app is killed.
    private func persistSessionIfDue() {
        guard Date().timeIntervalSince(lastSessionSave) >= Self.sessionSaveInterval else { return }
        persistSession()
    }

    private func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            MidgarLog.error("Watch audio session category failed: \(error.localizedDescription)", category: .playback)
        }
    }

    /// Long-form audio on watchOS must be activated with the asynchronous
    /// `activate(options:completionHandler:)` — it is what presents the
    /// Bluetooth route picker, and the synchronous `setActive(true)` throws for
    /// long-form sessions — so every play is gated behind it. Once the session
    /// is active, subsequent activations complete immediately.
    private func activateSessionAndPlay() {
        playIntentGeneration += 1
        let generation = playIntentGeneration
        isActivationPending = true
        AVAudioSession.sharedInstance().activate(options: []) { [weak self] success, error in
            Task { @MainActor in
                guard let self, generation == self.playIntentGeneration else { return }
                self.isActivationPending = false
                if success {
                    self.player?.play()
                } else {
                    MidgarLog.error(
                        "Watch audio session activate failed: \(error?.localizedDescription ?? "unknown error")",
                        category: .playback
                    )
                    self.isPlaying = false
                    self.updateNowPlayingInfo()
                    WKInterfaceDevice.current().play(.failure)
                }
            }
        }
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }
            let options = AVAudioSession.InterruptionOptions(
                rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            Task { @MainActor in self?.handleInterruption(type: type, options: options) }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
                  reason == .oldDeviceUnavailable
            else { return }
            Task { @MainActor in self?.handleRouteLoss() }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        })
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType, options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying || isActivationPending
            cancelPendingPlayIntent()
            player?.pause()
        case .ended:
            if wasPlayingBeforeInterruption, options.contains(.shouldResume) {
                activateSessionAndPlay()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    /// Route loss (headphones disconnect) must both pause and invalidate any
    /// activation completion in flight, or a stale play intent restarts audio
    /// on the speaker after the earbuds drop.
    private func handleRouteLoss() {
        cancelPendingPlayIntent()
        player?.pause()
    }

    /// mediaserverd crashes invalidate every AVFoundation object the app
    /// holds, so tear the player down completely; the next play/pause tap
    /// rebuilds it from scratch via `loadTrack`.
    private func handleMediaServicesReset() {
        MidgarLog.notice("Watch media services were reset, tearing down player", category: .playback)
        cancelPendingPlayIntent()
        removeObservers()
        timeControlObservation = nil
        player = nil
        isPlaying = false
        consecutiveFailures = 0
        configureSession()
        updateNowPlayingInfo()
    }

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                self.currentTime = seconds.isNaN ? 0 : seconds
                WatchPlayReporter.shared.playbackDidAdvance(elapsed: self.currentTime, isPlaying: self.isPlaying)
                self.persistSessionIfDue()
            }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            guard let finished = notification.object as? AVPlayerItem else { return }
            Task { @MainActor in
                self?.statusObservations.removeValue(forKey: ObjectIdentifier(finished))
                self?.handleTrackFinished()
            }
        }
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor in self?.handleItemFailed(item) }
        }
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
            self.failedToEndObserver = nil
        }
    }

    private func removeObservers() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        removeEndObserver()
        statusObservations.removeAll()
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { @Sendable [weak self] _ in
            onMainActorSync {
                guard let self, !self.isPlaying else { return .commandFailed }
                self.togglePlayPause()
                return .success
            }
        }
        center.pauseCommand.addTarget { @Sendable [weak self] _ in
            onMainActorSync {
                guard let self, self.isPlaying else { return .commandFailed }
                self.togglePlayPause()
                return .success
            }
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { @Sendable [weak self] _ in
            onMainActorSync {
                self?.next()
                return .success
            }
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { @Sendable [weak self] _ in
            onMainActorSync {
                self?.previous()
                return .success
            }
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            return onMainActorSync {
                guard let self else { return .commandFailed }
                self.seek(to: position)
                return .success
            }
        }
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { @Sendable [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            return onMainActorSync {
                guard let self else { return .commandFailed }
                self.seek(to: min(self.duration, self.currentTime + interval))
                return .success
            }
        }
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { @Sendable [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            return onMainActorSync {
                guard let self else { return .commandFailed }
                self.seek(to: max(0, self.currentTime - interval))
                return .success
            }
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.albumTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork = artwork(for: track) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Decoding artwork is too expensive to repeat on every now-playing
    /// refresh, so the decoded `MPMediaItemArtwork` is cached per track and
    /// rebuilt only when the current track changes.
    private func artwork(for track: MediaItem) -> MPMediaItemArtwork? {
        if let cachedArtwork, cachedArtwork.trackID == track.id {
            return cachedArtwork.artwork
        }
        guard let data = track.artworkData, let image = UIImage(data: data) else {
            cachedArtwork = nil
            return nil
        }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
        cachedArtwork = (track.id, artwork)
        return artwork
    }
}
