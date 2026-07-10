import AVFoundation
import FlaccyCore
import MediaPlayer
import Observation
import UIKit
import WatchKit

@MainActor
@Observable
final class WatchAudioPlayer: AudioPlaybackEngine {

    private(set) var queue: [MediaItem] = []
    private(set) var currentIndex: Int = 0
    private(set) var isPlaying: Bool = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var shuffleEnabled: Bool = false
    private(set) var currentTime: TimeInterval = 0

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
    @ObservationIgnored private var originalQueue: [MediaItem] = []

    init(documentsDirectory: URL) {
        self.documentsDirectory = documentsDirectory
        configureSession()
        configureRemoteCommands()
        observeAudioSession()
    }

    var currentItem: MediaItem? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    var duration: TimeInterval {
        guard let item = player?.currentItem else { return currentItem?.duration ?? 0 }
        let value = CMTimeGetSeconds(item.duration)
        if value.isNaN || value <= 0 { return currentItem?.duration ?? 0 }
        return value
    }

    func play(_ items: [MediaItem], startingAt index: Int) {
        guard !items.isEmpty, items.indices.contains(index) else { return }
        originalQueue = items
        if shuffleEnabled {
            var remaining = items
            let chosen = remaining.remove(at: index)
            remaining.shuffle()
            queue = [chosen] + remaining
            currentIndex = 0
        } else {
            queue = items
            currentIndex = index
        }
        WKInterfaceDevice.current().play(.click)
        loadTrack(at: currentIndex)
    }

    func togglePlayPause() {
        if !isPlaying, player?.items().isEmpty != false {
            guard !queue.isEmpty else { return }
            WKInterfaceDevice.current().play(.click)
            loadTrack(at: currentIndex)
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
        guard !queue.isEmpty else { return }
        if currentIndex + 1 < queue.count {
            currentIndex += 1
            loadTrack(at: currentIndex)
        } else if repeatMode == .all {
            currentIndex = 0
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
        currentIndex -= 1
        loadTrack(at: currentIndex)
    }

    func seek(to time: TimeInterval) {
        let target = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.currentTime = time
                self?.updateNowPlayingInfo()
            }
        }
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        WKInterfaceDevice.current().play(.click)
        guard queue.count > 1 else { return }
        let current = currentItem
        if shuffleEnabled {
            originalQueue = queue
            var remaining = queue
            if queue.indices.contains(currentIndex) { remaining.remove(at: currentIndex) }
            remaining.shuffle()
            queue = (current.map { [$0] } ?? []) + remaining
            currentIndex = 0
        } else {
            queue = originalQueue
            currentIndex = current.flatMap { originalQueue.firstIndex(of: $0) } ?? 0
        }
        resyncPreloadedItems()
    }

    func cycleRepeatMode() {
        repeatMode = repeatMode.next
        WKInterfaceDevice.current().play(.click)
        resyncPreloadedItems()
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
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        loadTrack(at: index)
    }

    private func loadTrack(at index: Int) {
        guard queue.indices.contains(index) else { return }
        removeObservers()

        let track = queue[index]
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
        currentTime = 0

        addTimeObserver()
        observeEnd(of: item)
        updateNowPlayingInfo()
        activateSessionAndPlay()
        AppLogger.info("Watch now playing: \(track.title) — \(track.artist)", category: .playback)
    }

    private func handleTrackFinished() {
        removeEndObserver()

        if repeatMode == .one {
            loadTrack(at: currentIndex)
            return
        }

        if currentIndex + 1 < queue.count {
            currentIndex += 1
            guard let nextItem = verifiedCurrentPlayerItem() else {
                loadTrack(at: currentIndex)
                return
            }
            currentTime = 0
            observeEnd(of: nextItem)
            preloadNextItem(after: currentIndex)
            activateSessionAndPlay()
            updateNowPlayingInfo()
            AppLogger.info("Watch gapless advance: \(queue[currentIndex].title)", category: .playback)
        } else if repeatMode == .all, !queue.isEmpty {
            currentIndex = 0
            loadTrack(at: currentIndex)
        } else {
            stopPlayback()
        }
    }

    /// The end-of-track notification races AVQueuePlayer's `.advance`
    /// transition, so `currentItem` may still be the just-finished item; only
    /// trust it when its URL matches the track the bookkeeping expects,
    /// otherwise the caller must rebuild deterministically via `loadTrack`.
    private func verifiedCurrentPlayerItem() -> AVPlayerItem? {
        guard let item = player?.currentItem,
              let url = (item.asset as? AVURLAsset)?.url,
              url == queue[currentIndex].fileURL(in: documentsDirectory)
        else { return nil }
        return item
    }

    private func preloadNextItem(after index: Int) {
        let nextIndex: Int
        if index + 1 < queue.count {
            nextIndex = index + 1
        } else if repeatMode == .all, !queue.isEmpty {
            nextIndex = 0
        } else {
            return
        }
        let nextItem = AVPlayerItem(url: queue[nextIndex].fileURL(in: documentsDirectory))
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
        AppLogger.error(
            "Watch player item failed: \(item.error?.localizedDescription ?? "unknown error")",
            category: .playback
        )
        statusObservations.removeValue(forKey: ObjectIdentifier(item))
        guard let player else { return }
        let wasCurrent = player.currentItem === item
        player.remove(item)
        guard wasCurrent else { return }
        consecutiveFailures += 1
        if consecutiveFailures >= max(queue.count, 1) {
            consecutiveFailures = 0
            stopPlayback()
            return
        }
        next()
    }

    private func stopPlayback() {
        cancelPendingPlayIntent()
        player?.pause()
        updateNowPlayingInfo()
    }

    /// Invalidates any activation completion still in flight so a stale play
    /// intent can never restart audio after the user or the system stopped it.
    private func cancelPendingPlayIntent() {
        playIntentGeneration += 1
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
            }
        }
    }

    private func configureSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            AppLogger.error("Watch audio session category failed: \(error.localizedDescription)", category: .playback)
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
                    AppLogger.error(
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
        AppLogger.warning("Watch media services were reset, tearing down player", category: .playback)
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
        center.playCommand.addTarget { [weak self] _ in
            guard let self, !self.isPlaying else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isPlaying else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seek(to: positionEvent.positionTime)
            return .success
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
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        cachedArtwork = (track.id, artwork)
        return artwork
    }
}
