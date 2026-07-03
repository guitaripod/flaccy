import ActivityKit
import AVFoundation
import FlaccyCore
import MediaPlayer
import Network
import UIKit

protocol AudioPlaying: AnyObject {
    var queue: [Track] { get }
    var currentIndex: Int { get }
    var isPlaying: Bool { get }
    var currentTrack: Track? { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var shuffleEnabled: Bool { get }
    var repeatMode: RepeatMode { get }
    func play(_ tracks: [Track], startingAt index: Int)
    func togglePlayPause()
    func nextTrack()
    func previousTrack()
    func seek(to time: TimeInterval)
    func toggleShuffle()
    func cycleRepeatMode()
    func clearQueue()
    func seekSmooth(to time: CMTime, tolerance: CMTime, completion: @escaping () -> Void)
    func jumpToIndex(_ index: Int)
    func removeFromQueue(at index: Int)
    func moveInQueue(from sourceIndex: Int, to destinationIndex: Int)
    func insertNext(_ track: Track)
    func addToQueue(_ track: Track)
    var sleepTimerRemaining: TimeInterval? { get }
    var sleepAtEndOfTrack: Bool { get }
    func setSleepTimer(minutes: Int)
    func setSleepTimerEndOfTrack()
    func cancelSleepTimer()
    func saveQueueState()
    func restoreQueueState()
    func retryPendingScrobbles() async
}

final class AudioPlayer: AudioPlaying {

    static let shared: AudioPlaying = AudioPlayer()

    static let playbackStateDidChange = Notification.Name("PlaybackStateDidChange")
    static let trackDidChange = Notification.Name("TrackDidChange")
    static let playbackProgressDidChange = Notification.Name("PlaybackProgressDidChange")
    static let shuffleRepeatDidChange = Notification.Name("ShuffleRepeatDidChange")
    static let queueDidChange = Notification.Name("QueueDidChange")
    static let sleepTimerDidUpdate = Notification.Name("SleepTimerDidUpdate")

    private var player: AVQueuePlayer?
    private var timeObserver: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var currentItemObservation: NSKeyValueObservation?
    private var playingItem: AVPlayerItem?
    private var preloadedItem: AVPlayerItem?
    private var preloadedIndex: Int?
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback = UISelectionFeedbackGenerator()

    private var sleepTimer: Timer?
    private(set) var sleepTimerRemaining: TimeInterval?
    private(set) var sleepAtEndOfTrack = false

    private var liveActivity: Activity<FlaccyActivityAttributes>?
    private var trackStartTime: Date?
    private var hasScrobbled: Bool = false
    private var originalQueue: [Track] = []
    private var lastKnownPlaybackPosition: TimeInterval = 0
    private var isRetryingScrobbles: Bool = false
    private var wasNetworkAvailable: Bool = false
    private let pathMonitor = NWPathMonitor()

    private(set) var queue: [Track] = []
    private(set) var currentIndex: Int = 0
    private(set) var isPlaying: Bool = false
    private(set) var shuffleEnabled: Bool = false
    private(set) var repeatMode: RepeatMode = .off

    var currentTrack: Track? {
        guard !queue.isEmpty, currentIndex >= 0, currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    var currentTime: TimeInterval {
        guard let player else { return 0 }
        let t = CMTimeGetSeconds(player.currentTime())
        return t.isNaN ? 0 : t
    }

    var duration: TimeInterval {
        guard let item = player?.currentItem else { return 0 }
        let d = CMTimeGetSeconds(item.duration)
        return d.isNaN ? 0 : d
    }

    private init() {
        configureRemoteCommands()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillResignActive), name: UIApplication.willResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMediaServicesReset), name: AVAudioSession.mediaServicesWereResetNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleItemFailedToPlayToEnd(_:)), name: .AVPlayerItemFailedToPlayToEndTime, object: nil
        )
        startNetworkMonitoring()
    }

    /// Retries pending scrobbles whenever connectivity is restored, so plays queued offline are submitted without waiting for the next app launch.
    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                let becameAvailable = isSatisfied && !self.wasNetworkAvailable
                self.wasNetworkAvailable = isSatisfied
                if becameAvailable {
                    Task { await self.retryPendingScrobbles() }
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "flaccy.network-monitor"))
    }

    @objc private func handleWillResignActive() {
        saveQueueState()
    }

    @objc private func handleWillEnterForeground() {
        Task { await retryPendingScrobbles() }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                if self.isPlaying {
                    self.player?.pause()
                    self.applyPlaybackState(false)
                }
            case .ended:
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
                if options.contains(.shouldResume) {
                    self.activateSession()
                    self.player?.play()
                    self.applyPlaybackState(true)
                }
            @unknown default:
                break
            }
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
              reason == .oldDeviceUnavailable
        else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPlaying else { return }
            self.player?.pause()
            self.applyPlaybackState(false)
        }
    }

    /// Rebuilds the player after mediaserverd crashes, which invalidates every AVFoundation object the app holds.
    @objc private func handleMediaServicesReset() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            AppLogger.warning("Media services were reset, rebuilding player", category: .content)
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
            NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
        }
    }

    /// Skips past an item that cannot finish decoding so one corrupt file never stalls the whole queue.
    @objc private func handleItemFailedToPlayToEnd(_ notification: Notification) {
        let failedItem = notification.object as? AVPlayerItem
        DispatchQueue.main.async { [weak self] in
            guard let self, let failedItem, failedItem === self.playingItem else { return }
            let errorDescription = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "unknown"
            AppLogger.error("Item failed to play to end at index \(self.currentIndex): \(errorDescription)", category: .playback)
            self.nextTrack()
        }
    }

    private func applyPlaybackState(_ playing: Bool) {
        isPlaying = playing
        updateNowPlayingInfo()
        updateLiveActivity()
        NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
    }

    func play(_ tracks: [Track], startingAt index: Int) {
        guard !tracks.isEmpty, index >= 0, index < tracks.count else { return }
        checkScrobbleOnSkip()
        originalQueue = tracks
        if shuffleEnabled {
            let currentTrack = tracks[index]
            var remaining = tracks
            remaining.remove(at: index)
            remaining.shuffle()
            queue = [currentTrack] + remaining
            currentIndex = 0
        } else {
            queue = tracks
            currentIndex = index
        }
        impactMedium.impactOccurred()
        loadTrack(at: currentIndex)
        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
    }

    func togglePlayPause() {
        guard let player else { return }
        impactLight.impactOccurred()
        if !isPlaying, player.currentItem == nil, queue.indices.contains(currentIndex) {
            loadTrack(at: currentIndex)
            return
        }
        if isPlaying {
            player.pause()
        } else {
            activateSession()
            player.play()
        }
        applyPlaybackState(!isPlaying)
    }

    func nextTrack() {
        checkScrobbleOnSkip()
        guard currentIndex + 1 < queue.count else {
            if repeatMode == .all && !queue.isEmpty {
                currentIndex = 0
                selectionFeedback.selectionChanged()
                loadTrack(at: currentIndex)
            } else {
                player?.pause()
                applyPlaybackState(false)
            }
            return
        }
        currentIndex += 1
        selectionFeedback.selectionChanged()
        loadTrack(at: currentIndex)
    }

    func previousTrack() {
        if currentTime > 3 {
            selectionFeedback.selectionChanged()
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.updateNowPlayingInfo()
                self?.updateLiveActivity()
                NotificationCenter.default.post(name: AudioPlayer.playbackProgressDidChange, object: nil)
            }
            return
        }
        checkScrobbleOnSkip()
        guard currentIndex > 0 else {
            player?.seek(to: .zero)
            return
        }
        currentIndex -= 1
        selectionFeedback.selectionChanged()
        loadTrack(at: currentIndex)
    }

    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.updateNowPlayingInfo()
            self?.updateLiveActivity()
            NotificationCenter.default.post(name: AudioPlayer.playbackProgressDidChange, object: nil)
        }
    }

    func seekSmooth(to time: CMTime, tolerance: CMTime, completion: @escaping () -> Void) {
        player?.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            if finished {
                self?.updateNowPlayingInfo()
                self?.updateLiveActivity()
            }
            completion()
        }
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        impactLight.impactOccurred()

        if queue.count > 1 {
            let current = currentTrack
            if shuffleEnabled {
                originalQueue = queue
                var remaining = queue
                remaining.remove(at: currentIndex)
                remaining.shuffle()
                if let current {
                    queue = [current] + remaining
                } else {
                    queue = remaining
                }
                currentIndex = 0
            } else {
                if let current, let idx = originalQueue.firstIndex(of: current) {
                    queue = originalQueue
                    currentIndex = idx
                } else {
                    queue = originalQueue
                    currentIndex = 0
                }
            }
        }

        resyncPreloadedItems()
        NotificationCenter.default.post(name: AudioPlayer.shuffleRepeatDidChange, object: nil)
        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        impactLight.impactOccurred()
        resyncPreloadedItems()
        NotificationCenter.default.post(name: AudioPlayer.shuffleRepeatDidChange, object: nil)
    }

    func clearQueue() {
        removePlayerObservers()
        playingItem = nil
        preloadedItem = nil
        preloadedIndex = nil
        player?.pause()
        player?.removeAllItems()
        isPlaying = false
        queue = []
        originalQueue = []
        currentIndex = 0
        lastKnownPlaybackPosition = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        endLiveActivity()
        impactMedium.impactOccurred()
        NotificationCenter.default.post(name: AudioPlayer.trackDidChange, object: nil)
        NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
    }

    func jumpToIndex(_ index: Int) {
        guard index >= 0, index < queue.count else { return }
        checkScrobbleOnSkip()
        currentIndex = index
        selectionFeedback.selectionChanged()
        loadTrack(at: currentIndex)
    }

    func removeFromQueue(at index: Int) {
        guard index >= 0, index < queue.count, index != currentIndex else { return }
        let track = queue[index]
        queue.remove(at: index)
        if let origIdx = originalQueue.firstIndex(of: track) {
            originalQueue.remove(at: origIdx)
        }
        if index < currentIndex {
            currentIndex -= 1
        }
        resyncPreloadedItems()
        impactLight.impactOccurred()
        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
    }

    func moveInQueue(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < queue.count,
              destinationIndex >= 0, destinationIndex < queue.count,
              sourceIndex != destinationIndex
        else { return }

        let playing = currentTrack
        let track = queue.remove(at: sourceIndex)
        queue.insert(track, at: destinationIndex)
        if let playing, let idx = queue.firstIndex(of: playing) {
            currentIndex = idx
        }

        resyncPreloadedItems()
        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
    }

    func insertNext(_ track: Track) {
        let insertIndex = min(currentIndex + 1, queue.count)
        queue.insert(track, at: insertIndex)
        if let current = currentTrack, let origIdx = originalQueue.firstIndex(of: current) {
            originalQueue.insert(track, at: min(origIdx + 1, originalQueue.count))
        } else {
            originalQueue.append(track)
        }
        resyncPreloadedItems()
        impactLight.impactOccurred()
        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
    }

    func addToQueue(_ track: Track) {
        queue.append(track)
        originalQueue.append(track)
        resyncPreloadedItems()
        impactLight.impactOccurred()
        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
    }

    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        sleepTimerRemaining = TimeInterval(minutes * 60)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let remaining = self.sleepTimerRemaining {
                self.sleepTimerRemaining = remaining - 1
                NotificationCenter.default.post(name: AudioPlayer.sleepTimerDidUpdate, object: nil)
                if remaining <= 1 {
                    self.cancelSleepTimer()
                    self.player?.pause()
                    self.applyPlaybackState(false)
                }
            }
        }
        NotificationCenter.default.post(name: AudioPlayer.sleepTimerDidUpdate, object: nil)
        impactLight.impactOccurred()
    }

    func setSleepTimerEndOfTrack() {
        cancelSleepTimer()
        sleepAtEndOfTrack = true
        NotificationCenter.default.post(name: AudioPlayer.sleepTimerDidUpdate, object: nil)
        impactLight.impactOccurred()
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerRemaining = nil
        sleepAtEndOfTrack = false
        NotificationCenter.default.post(name: AudioPlayer.sleepTimerDidUpdate, object: nil)
    }

    private func makeConfiguredPlayer(with item: AVPlayerItem) -> AVQueuePlayer {
        let player = AVQueuePlayer(items: [item])
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .advance
        installTimeControlObservation(on: player)
        installCurrentItemObservation(on: player)
        return player
    }

    /// Single authoritative advance path: every change of the queue player's currentItem
    /// (auto-advance at item end, queue exhaustion, repeat-one restart) flows through here,
    /// with all comparisons done against live player state on the main queue so delayed
    /// delivery can never bind bookkeeping to an already-finished item.
    private func installCurrentItemObservation(on player: AVQueuePlayer) {
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleCurrentItemChanged() }
        }
    }

    private func handleCurrentItemChanged() {
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
            AppLogger.warning("Advance resolved by URL match to index \(resolvedIndex) (preload bookkeeping was stale)", category: .playback)
            completeAutoAdvance(to: resolvedIndex, item: item)
            return
        }
        AppLogger.warning("Unrecognized current item after advance, reloading index \(currentIndex)", category: .playback)
        loadTrack(at: currentIndex)
    }

    /// Recovers the queue index for an item the preload bookkeeping no longer knows,
    /// e.g. after two back-to-back advances raced a single main-queue hop.
    private func resolveQueueIndex(for item: AVPlayerItem) -> Int? {
        guard let url = (item.asset as? AVURLAsset)?.url, !queue.isEmpty else { return nil }
        let ordered = Array(queue.indices.dropFirst(currentIndex + 1)) + Array(queue.indices.prefix(currentIndex + 1))
        return ordered.first { queue[$0].fileURL == url }
    }

    private func completeAutoAdvance(to nextIndex: Int, item: AVPlayerItem) {
        guard queue.indices.contains(nextIndex) else {
            AppLogger.warning("Auto-advance target index \(nextIndex) out of bounds (queue count \(queue.count))", category: .playback)
            handleQueueExhausted()
            return
        }
        if !hasScrobbled {
            performScrobble()
        }

        let previousIndex = currentIndex
        currentIndex = nextIndex
        playingItem = item
        preloadedItem = nil
        preloadedIndex = nil
        trackStartTime = Date()
        hasScrobbled = false
        lastKnownPlaybackPosition = 0

        let track = queue[currentIndex]
        AppLogger.info("Auto-advance \(previousIndex) -> \(currentIndex): \(track.title) - \(track.artist)", category: .playback)

        resyncPreloadedItems()

        if sleepAtEndOfTrack {
            cancelSleepTimer()
            player?.pause()
            applyPlaybackState(false)
        } else {
            activateSession()
            player?.play()
            isPlaying = true
        }

        updateNowPlayingInfo()
        ensureArtworkLoaded(for: track)
        sendNowPlayingToLastFM(track: track)

        endLiveActivity()
        startLiveActivity()

        NotificationCenter.default.post(name: AudioPlayer.trackDidChange, object: nil)
        NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
    }

    private func handleQueueExhausted() {
        guard playingItem != nil else { return }
        AppLogger.info("Queue exhausted at index \(currentIndex), stopping", category: .playback)
        if !hasScrobbled {
            performScrobble()
        }
        playingItem = nil
        preloadedItem = nil
        preloadedIndex = nil
        if sleepAtEndOfTrack {
            cancelSleepTimer()
        }
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
        endLiveActivity()
        NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
    }

    /// Derives isPlaying from the player's timeControlStatus so system-initiated pauses (route loss, resource contention) keep app and lock-screen state in sync.
    private func installTimeControlObservation(on player: AVQueuePlayer) {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            let playing = observedPlayer.timeControlStatus != .paused
            DispatchQueue.main.async {
                guard let self, self.isPlaying != playing else { return }
                self.applyPlaybackState(playing)
            }
        }
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func removePlayerObservers() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func loadTrack(at index: Int) {
        guard index >= 0, index < queue.count else { return }

        removePlayerObservers()

        let track = queue[index]
        let item = AVPlayerItem(url: track.fileURL)

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

        activateSession()
        player?.play()
        isPlaying = true

        trackStartTime = Date()
        hasScrobbled = false
        lastKnownPlaybackPosition = 0

        startTimeObserver()

        AppLogger.info("Load track \(index): \(track.title) - \(track.artist)", category: .playback)
        updateNowPlayingInfo()
        ensureArtworkLoaded(for: track)
        sendNowPlayingToLastFM(track: track)

        endLiveActivity()
        startLiveActivity()

        NotificationCenter.default.post(name: AudioPlayer.trackDidChange, object: nil)
        NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
    }

    private func preloadNextItem(after index: Int) {
        let nextIndex: Int
        if repeatMode == .one {
            nextIndex = index
        } else if index + 1 < queue.count {
            nextIndex = index + 1
        } else if repeatMode == .all && !queue.isEmpty {
            nextIndex = 0
        } else {
            return
        }
        guard queue.indices.contains(nextIndex) else { return }
        let nextItem = AVPlayerItem(url: queue[nextIndex].fileURL)
        if player?.canInsert(nextItem, after: player?.items().last) == true {
            player?.insert(nextItem, after: player?.items().last)
            preloadedItem = nextItem
            preloadedIndex = nextIndex
            AppLogger.info("Preloaded index \(nextIndex) after \(index)", category: .playback)
        } else {
            AppLogger.warning("canInsert returned false for track \(nextIndex): \(queue[nextIndex].title)", category: .playback)
        }
    }

    /// Drops every preloaded item after the current one and preloads again, so queue, shuffle, and repeat mutations can never leave stale audio in the player.
    private func resyncPreloadedItems() {
        guard let player, player.currentItem != nil else { return }
        for item in player.items().dropFirst() {
            player.remove(item)
        }
        preloadedItem = nil
        preloadedIndex = nil
        preloadNextItem(after: currentIndex)
    }

    private func startTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lastKnownPlaybackPosition = self.currentTime
            self.checkScrobbleCriteria()
            NotificationCenter.default.post(name: AudioPlayer.playbackProgressDidChange, object: nil)
        }
    }

    private func checkScrobbleOnSkip() {
        guard !hasScrobbled, let track = currentTrack, track.duration > 0 else { return }
        if meetsScrobbleCriteria(elapsed: currentTime, trackDuration: track.duration) {
            performScrobble()
        }
    }

    private func checkScrobbleCriteria() {
        guard !hasScrobbled, let track = currentTrack, track.duration > 0 else { return }
        if meetsScrobbleCriteria(elapsed: currentTime, trackDuration: track.duration) {
            performScrobble()
        }
    }

    private func meetsScrobbleCriteria(elapsed: TimeInterval, trackDuration: TimeInterval) -> Bool {
        let threshold = min(240, max(30, trackDuration / 2))
        return elapsed >= threshold
    }

    private func performScrobble() {
        guard let track = currentTrack else { return }
        hasScrobbled = true
        let startTime = trackStartTime ?? Date()
        let trackDuration = Int(track.duration)

        let dbID = track.dbID

        Task { [track, startTime, trackDuration, dbID] in
            if let dbID {
                do {
                    try DatabaseManager.shared.incrementPlayCount(trackId: dbID)
                } catch {
                    AppLogger.error("Failed to increment play count: \(error.localizedDescription)", category: .database)
                }
            }

            let record = ScrobbleRecord(
                trackTitle: track.title,
                artist: track.artist,
                albumTitle: track.albumTitle,
                timestamp: startTime,
                duration: trackDuration,
                submitted: false
            )
            do {
                try DatabaseManager.shared.insertScrobble(record)
            } catch {
                AppLogger.error("Failed to persist pending scrobble: \(error.localizedDescription)", category: .database)
            }

            let success = await LastFMService.shared.scrobble(
                track: track.title,
                artist: track.artist,
                album: track.albumTitle,
                timestamp: startTime,
                duration: trackDuration
            )

            if success {
                self.markScrobbleSubmitted(trackTitle: track.title, timestamp: startTime)
            } else {
                AppLogger.info("Scrobble left pending for retry: \(track.title)", category: .sync)
            }
        }
    }

    /// Marks the write-ahead pending row as submitted after a successful network scrobble, matching on title plus timestamp since insertScrobble does not return the row id.
    private func markScrobbleSubmitted(trackTitle: String, timestamp: Date) {
        do {
            let pending = try DatabaseManager.shared.fetchPendingScrobbles()
            let ids = pending
                .filter { $0.trackTitle == trackTitle && abs($0.timestamp.timeIntervalSince(timestamp)) < 1 }
                .compactMap(\.id)
            try DatabaseManager.shared.markScrobblesSubmitted(ids: ids)
        } catch {
            AppLogger.error("Failed to mark scrobble submitted: \(error.localizedDescription)", category: .database)
        }
    }

    private func sendNowPlayingToLastFM(track: Track) {
        Task {
            await LastFMService.shared.updateNowPlaying(
                track: track.title,
                artist: track.artist,
                album: track.albumTitle,
                duration: Int(track.duration)
            )
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.isPlaying else { return }
                self.togglePlayPause()
            }
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isPlaying else { return }
                self.togglePlayPause()
            }
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.togglePlayPause() }
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.nextTrack() }
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.previousTrack() }
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            DispatchQueue.main.async { self?.seek(to: positionEvent.positionTime) }
            return .success
        }
    }

    private func resolveArtwork(for track: Track) -> UIImage? {
        track.artwork ?? AlbumArtworkCache.shared.artwork(forAlbum: track.albumTitle, artist: track.artist)
    }

    private func ensureArtworkLoaded(for track: Track) {
        guard resolveArtwork(for: track) == nil else { return }
        AlbumArtworkCache.shared.loadArtwork(forAlbum: track.albumTitle, artist: track.artist) { [weak self] _ in
            self?.updateNowPlayingInfo()
            self?.updateLiveActivity()
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let reportedDuration = duration > 0 ? duration : track.duration
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.albumTitle,
            MPMediaItemPropertyPlaybackDuration: reportedDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]

        if let artwork = resolveArtwork(for: track) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: artwork.size
            ) { _ in artwork }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Produces a thumbnail small enough that the encoded ActivityAttributes stay under ActivityKit's 4KB payload limit.
    private func liveActivityArtworkData(for track: Track) -> Data? {
        guard let artwork = resolveArtwork(for: track) else { return nil }
        let side: CGFloat = 96
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            artwork.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        for quality in [0.7, 0.5, 0.3] {
            if let data = thumbnail.jpegData(compressionQuality: quality), data.count < 3000 {
                return data
            }
        }
        return nil
    }

    private func makeLiveActivityContentState() -> FlaccyActivityAttributes.ContentState? {
        guard let track = currentTrack else { return nil }
        let elapsed = currentTime
        let trackDuration = duration > 0 ? duration : track.duration
        return FlaccyActivityAttributes.ContentState(
            title: track.title,
            artist: track.artist,
            albumTitle: track.albumTitle,
            isPlaying: isPlaying,
            playbackStartDate: Date().addingTimeInterval(-elapsed),
            pausedElapsed: elapsed,
            duration: trackDuration
        )
    }

    private func makeLiveActivityContent(state: FlaccyActivityAttributes.ContentState) -> ActivityContent<FlaccyActivityAttributes.ContentState> {
        let staleDate = state.isPlaying && state.duration > 0
            ? state.playbackStartDate.addingTimeInterval(state.duration)
            : nil
        return ActivityContent(state: state, staleDate: staleDate)
    }

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let track = currentTrack, let state = makeLiveActivityContentState() else { return }

        let attributes = FlaccyActivityAttributes(artworkData: liveActivityArtworkData(for: track))

        do {
            liveActivity = try Activity.request(attributes: attributes, content: makeLiveActivityContent(state: state), pushType: nil)
        } catch {
            AppLogger.error("Failed to start live activity: \(error.localizedDescription)", category: .ui)
        }
    }

    private func updateLiveActivity() {
        guard let state = makeLiveActivityContentState() else {
            endLiveActivity()
            return
        }
        guard let activity = liveActivity else { return }
        let content = makeLiveActivityContent(state: state)
        Task { await activity.update(content) }
    }

    private func endLiveActivity() {
        guard let activity = liveActivity else { return }
        liveActivity = nil
        let state = FlaccyActivityAttributes.ContentState(
            title: currentTrack?.title ?? "",
            artist: currentTrack?.artist ?? "",
            albumTitle: currentTrack?.albumTitle ?? "",
            isPlaying: false,
            playbackStartDate: Date(),
            pausedElapsed: 0,
            duration: 0
        )
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .immediate) }
    }

    func saveQueueState() {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
        let paths = queue.map { track -> String in
            let trackPath = track.fileURL.standardizedFileURL.path
            let docsPath = docsDir.path
            if trackPath.hasPrefix(docsPath) {
                let rel = String(trackPath.dropFirst(docsPath.count))
                return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
            }
            return track.fileURL.lastPathComponent
        }
        UserDefaults.standard.set(paths, forKey: "flaccy.queue.paths")
        UserDefaults.standard.set(currentIndex, forKey: "flaccy.queue.index")
        if paths.indices.contains(currentIndex) {
            UserDefaults.standard.set(paths[currentIndex], forKey: "flaccy.queue.currentPath")
        } else {
            UserDefaults.standard.removeObject(forKey: "flaccy.queue.currentPath")
        }
        UserDefaults.standard.set(currentTime, forKey: "flaccy.queue.elapsed")
        UserDefaults.standard.set(shuffleEnabled, forKey: "flaccy.queue.shuffle")
        UserDefaults.standard.set(repeatMode == .all ? 1 : repeatMode == .one ? 2 : 0, forKey: "flaccy.queue.repeat")
    }

    func restoreQueueState() {
        guard let paths = UserDefaults.standard.stringArray(forKey: "flaccy.queue.paths"),
              !paths.isEmpty else { return }

        let savedIndex = UserDefaults.standard.integer(forKey: "flaccy.queue.index")
        let savedElapsed = UserDefaults.standard.double(forKey: "flaccy.queue.elapsed")
        let savedShuffle = UserDefaults.standard.bool(forKey: "flaccy.queue.shuffle")
        let savedRepeat = UserDefaults.standard.integer(forKey: "flaccy.queue.repeat")
        let savedCurrentPath = UserDefaults.standard.string(forKey: "flaccy.queue.currentPath")

        var restoredTracks: [Track] = []
        var restoredPaths: [String] = []
        for path in paths {
            guard let record = try? DatabaseManager.shared.fetchTrack(byRelativePath: path) else { continue }
            let artwork: UIImage?
            if let albumInfo = try? DatabaseManager.shared.fetchAlbumInfo(title: record.albumTitle, artist: record.artist),
               let data = albumInfo.coverArtData {
                artwork = UIImage(data: data)
            } else {
                artwork = ImageCache.shared.imageFromData(record.artworkData)
            }
            restoredTracks.append(Track.from(record: record, artwork: artwork))
            restoredPaths.append(path)
        }

        guard !restoredTracks.isEmpty else { return }

        queue = restoredTracks
        originalQueue = restoredTracks

        let resumeElapsed: Double
        if let savedCurrentPath, let idx = restoredPaths.firstIndex(of: savedCurrentPath) {
            currentIndex = idx
            resumeElapsed = savedElapsed
        } else if savedCurrentPath != nil {
            currentIndex = 0
            resumeElapsed = 0
        } else {
            currentIndex = min(max(savedIndex, 0), restoredTracks.count - 1)
            resumeElapsed = savedElapsed
        }

        shuffleEnabled = savedShuffle
        repeatMode = savedRepeat == 1 ? .all : savedRepeat == 2 ? .one : .off

        rebuildPlayerPaused(at: resumeElapsed)

        NotificationCenter.default.post(name: AudioPlayer.trackDidChange, object: nil)
        NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
        NotificationCenter.default.post(name: AudioPlayer.shuffleRepeatDidChange, object: nil)

        AppLogger.info("Restored queue: \(restoredTracks.count) tracks, index \(currentIndex), elapsed \(resumeElapsed)s", category: .content)
    }

    /// Rebuilds the player around the current queue index and leaves playback paused at the given position; shared by queue restore and media-services recovery.
    private func rebuildPlayerPaused(at position: TimeInterval) {
        guard let track = currentTrack else { return }

        removePlayerObservers()

        let item = AVPlayerItem(url: track.fileURL)
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

        if position > 0 {
            let cmTime = CMTime(seconds: position, preferredTimescale: 600)
            player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        startTimeObserver()
        updateNowPlayingInfo()
    }

    func retryPendingScrobbles() async {
        guard !isRetryingScrobbles else { return }
        guard LastFMService.shared.isAuthenticated else { return }
        isRetryingScrobbles = true
        defer { isRetryingScrobbles = false }
        do {
            let pending = try DatabaseManager.shared.fetchPendingScrobbles()
            guard !pending.isEmpty else { return }

            AppLogger.info("Retrying \(pending.count) pending scrobbles", category: .sync)

            let tuples = pending.compactMap { record -> (id: Int64, track: String, artist: String, album: String, timestamp: Date, duration: Int)? in
                guard let id = record.id else { return nil }
                return (id: id, track: record.trackTitle, artist: record.artist, album: record.albumTitle, timestamp: record.timestamp, duration: record.duration)
            }
            let submittedIds = await LastFMService.shared.submitPendingScrobbles(scrobbles: tuples)

            if !submittedIds.isEmpty {
                try DatabaseManager.shared.markScrobblesSubmitted(ids: submittedIds)
            }
            AppLogger.info("Scrobble retry: \(submittedIds.count)/\(pending.count) submitted", category: .sync)
        } catch {
            AppLogger.error("Scrobble retry failed: \(error.localizedDescription)", category: .sync)
        }
    }
}
