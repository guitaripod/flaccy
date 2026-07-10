import AVFoundation
import FlaccyCore
import MediaPlayer
import Network

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

protocol AudioPlaying: AnyObject {
    var queue: [Track] { get }
    var currentIndex: Int { get }
    var isPlaying: Bool { get }
    var currentTrack: Track? { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var shuffleEnabled: Bool { get }
    var repeatMode: RepeatMode { get }
    var autoplaySimilarWhenQueueEnds: Bool { get set }
    func startStation(seedArtist: String)
    func startStation(seedTrack: Track)
    func playLibraryRadio()
    func play(_ tracks: [Track], startingAt index: Int)
    func togglePlayPause()
    func nextTrack()
    func previousTrack()
    func seek(to time: TimeInterval)
    func toggleShuffle()
    func cycleRepeatMode()
    func clearUpNext()
    func seekSmooth(to time: CMTime, tolerance: CMTime, completion: @escaping () -> Void)
    func jumpToIndex(_ index: Int)
    func removeFromQueue(at index: Int)
    func handleDeletedTracks(_ urls: Set<URL>)
    func moveInQueue(from sourceIndex: Int, to destinationIndex: Int)
    func insertNext(_ track: Track)
    func addToQueue(_ track: Track)
    #if os(macOS)
    var volume: Float { get set }
    #endif
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
    private let feedback = PlaybackFeedback()

    private var sleepTimer: Timer?
    private(set) var sleepTimerRemaining: TimeInterval?
    private(set) var sleepAtEndOfTrack = false

    private var trackStartTime: Date?
    private var hasScrobbled: Bool = false
    private var originalQueue: [Track] = []
    private var lastKnownPlaybackPosition: TimeInterval = 0
    private var isRetryingScrobbles: Bool = false
    private var scrobbleRetryRequested: Bool = false
    private var isRestoringQueue: Bool = false
    private var wasNetworkAvailable: Bool = false
    private var wasPlayingBeforeInterruption = false
    private var userPausedPlayback = false
    private let pathMonitor = NWPathMonitor()

    private(set) var queue: [Track] = []
    private(set) var currentIndex: Int = 0
    private(set) var isPlaying: Bool = false
    private(set) var shuffleEnabled: Bool = false
    private(set) var repeatMode: RepeatMode = .off

    private let autoplayDefaultsKey = "flaccy.autoplaySimilarWhenQueueEnds"
    private var stationSeedArtist: String?
    private var isBuildingStation = false
    private var autoplayContinuationInFlight = false

    /// When enabled, an exhausted queue is extended with a similar-artist / most-played
    /// continuation instead of stopping, so music never just ends. Persisted; default on.
    var autoplaySimilarWhenQueueEnds: Bool {
        get { UserDefaults.standard.object(forKey: autoplayDefaultsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: autoplayDefaultsKey)
            AppLogger.info("Autoplay similar when queue ends set to \(newValue)", category: .playback)
        }
    }

    var currentTrack: Track? {
        guard !queue.isEmpty, currentIndex >= 0, currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    /// Reads off `playingItem` rather than the queue player so the value never
    /// jumps to the preloaded next item during the auto-advance window, where
    /// `player.currentItem` has already switched but bookkeeping hasn't.
    var currentTime: TimeInterval {
        guard let item = playingItem ?? player?.currentItem else { return 0 }
        let t = CMTimeGetSeconds(item.currentTime())
        return t.isFinite && t >= 0 ? t : 0
    }

    /// Anchored to `playingItem` for the same auto-advance-race reason as
    /// `currentTime`, and falls back to the track's metadata duration while the
    /// asset is still loading (an unresolved AVPlayerItem reports indefinite),
    /// so the timeline never shows a stale or zero total.
    var duration: TimeInterval {
        if let item = playingItem ?? player?.currentItem {
            let d = CMTimeGetSeconds(item.duration)
            if d.isFinite, d > 0 { return d }
        }
        return currentTrack?.duration ?? 0
    }

    private init() {
        configureRemoteCommands()
        #if os(iOS)
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
        #elseif os(macOS)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillResignActive), name: NSApplication.willResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillResignActive), name: NSApplication.willTerminateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillEnterForeground), name: NSApplication.didBecomeActiveNotification, object: nil
        )
        #endif
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleItemFailedToPlayToEnd(_:)), name: .AVPlayerItemFailedToPlayToEndTime, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleLastFMAuthChange), name: LastFMService.authDidChange, object: nil
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

    /// Connecting flushes anything queued while offline; disconnecting retires
    /// the pending queue so plays stay as local history and nothing waits on an
    /// account the user opted out of.
    @objc private func handleLastFMAuthChange() {
        if LastFMService.shared.isAuthenticated {
            Task { await retryPendingScrobbles() }
        } else {
            do {
                try DatabaseManager.shared.retirePendingScrobbles(olderThan: .distantFuture)
            } catch {
                AppLogger.error("Failed to retire pending scrobbles on disconnect: \(error.localizedDescription)", category: .database)
            }
        }
    }

    @objc private func handleWillEnterForeground() {
        Task { await retryPendingScrobbles() }
    }

    #if os(iOS)
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
                    self.activateSession()
                    self.player?.play()
                    self.applyPlaybackState(true)
                }
                self.wasPlayingBeforeInterruption = false
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
            self.userPausedPlayback = true
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
    #endif

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
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
        #endif
        NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
    }

    /// Single gating choke point for starting playback: every entry that begins
    /// audio (library taps, stations, radio, skips, queue jumps, remote commands)
    /// loads through loadTrack(at:), and the direct-resume branch of
    /// togglePlayPause re-checks before resuming an already-loaded item; both
    /// defer to the paywall once the trial has expired without a purchase.
    private func playbackIsGated() -> Bool {
        guard !PurchaseManager.shared.allowsPlayback else { return false }
        PurchaseManager.shared.requestPaywall()
        return true
    }

    func play(_ tracks: [Track], startingAt index: Int) {
        play(tracks, startingAt: index, stationSeed: nil)
    }

    /// Every queue replacement flows through here so the autoplay-continuation
    /// seed is deterministically set for stations and cleared for ordinary
    /// plays, never leaking a stale station artist into unrelated listening.
    private func play(_ tracks: [Track], startingAt index: Int, stationSeed: String?) {
        guard !tracks.isEmpty, index >= 0, index < tracks.count else { return }
        if playbackIsGated() { return }
        stationSeedArtist = stationSeed
        checkScrobbleOnSkip()
        originalQueue = tracks
        if shuffleEnabled {
            let currentTrack = tracks[index]
            var remaining = tracks
            remaining.remove(at: index)
            remaining = historyAwareShuffle(remaining)
            queue = [currentTrack] + remaining
            currentIndex = 0
        } else {
            queue = tracks
            currentIndex = index
        }
        feedback.medium()
        loadTrack(at: currentIndex)
        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
    }

    func togglePlayPause() {
        wasPlayingBeforeInterruption = false
        guard let player else {
            if playbackIsGated() { return }
            if queue.indices.contains(currentIndex) {
                feedback.light()
                loadTrack(at: currentIndex)
            }
            return
        }
        feedback.light()
        if !isPlaying, playbackIsGated() { return }
        if !isPlaying, player.currentItem == nil, queue.indices.contains(currentIndex) {
            loadTrack(at: currentIndex)
            return
        }
        if isPlaying {
            userPausedPlayback = true
            player.pause()
        } else {
            userPausedPlayback = false
            activateSession()
            player.play()
        }
        applyPlaybackState(!isPlaying)
    }

    func nextTrack() {
        checkScrobbleOnSkip()
        guard currentIndex + 1 < queue.count else {
            if repeatMode == .all && !queue.isEmpty {
                feedback.selection()
                loadTrack(at: 0)
            } else {
                player?.pause()
                applyPlaybackState(false)
            }
            return
        }
        feedback.selection()
        loadTrack(at: currentIndex + 1)
    }

    func previousTrack() {
        if currentTime > 3 {
            feedback.selection()
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.updateNowPlayingInfo()
                NotificationCenter.default.post(name: AudioPlayer.playbackProgressDidChange, object: nil)
            }
            return
        }
        checkScrobbleOnSkip()
        guard currentIndex > 0 else {
            player?.seek(to: .zero)
            return
        }
        feedback.selection()
        loadTrack(at: currentIndex - 1)
    }

    func seek(to time: TimeInterval) {
        guard let player, player.currentItem === playingItem else { return }
        let cmTime = CMTime(seconds: clampedSeekTarget(time), preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.updateNowPlayingInfo()
            NotificationCenter.default.post(name: AudioPlayer.playbackProgressDidChange, object: nil)
        }
    }

    func seekSmooth(to time: CMTime, tolerance: CMTime, completion: @escaping () -> Void) {
        guard let player, player.currentItem === playingItem else {
            completion()
            return
        }
        let target = CMTime(seconds: clampedSeekTarget(CMTimeGetSeconds(time)), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            if finished {
                self?.updateNowPlayingInfo()
            }
            completion()
        }
    }

    /// Keeps every seek inside the real item bounds, stopping a hair short of
    /// the end so a scrub released at 100% plays out naturally instead of
    /// slamming item-end and force-advancing the queue mid-gesture.
    private func clampedSeekTarget(_ time: TimeInterval) -> TimeInterval {
        let total = duration
        guard total > 0 else { return max(0, time) }
        return min(max(0, time), max(0, total - 0.25))
    }

    /// Purges deleted files from the queue: keeps position when the playing
    /// track survives, advances to the nearest remaining track when it was
    /// deleted mid-play, and stops cleanly when nothing is left.
    func handleDeletedTracks(_ urls: Set<URL>) {
        guard !queue.isEmpty, queue.contains(where: { urls.contains($0.fileURL) }) else { return }
        let playingURL = currentTrack?.fileURL
        let wasPlaying = isPlaying
        originalQueue.removeAll { urls.contains($0.fileURL) }
        var remaining = queue
        remaining.removeAll { urls.contains($0.fileURL) }

        if remaining.isEmpty {
            queue = []
            currentIndex = 0
            player?.pause()
            player?.removeAllItems()
            playingItem = nil
            preloadedItem = nil
            preloadedIndex = nil
            isPlaying = false
            updateNowPlayingInfo()
            NotificationCenter.default.post(name: AudioPlayer.trackDidChange, object: nil)
            NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
            NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
            return
        }

        if let playingURL, !urls.contains(playingURL) {
            queue = remaining
            currentIndex = remaining.firstIndex { $0.fileURL == playingURL } ?? 0
            resyncPreloadedItems()
        } else {
            let survivorsBefore = queue[..<currentIndex].filter { !urls.contains($0.fileURL) }.count
            queue = remaining
            currentIndex = min(survivorsBefore, remaining.count - 1)
            loadTrack(at: currentIndex)
            if !wasPlaying {
                userPausedPlayback = true
                player?.pause()
                isPlaying = false
                updateNowPlayingInfo()
                NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
            }
        }
        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        feedback.light()

        if queue.count > 1 {
            let current = currentTrack
            if shuffleEnabled {
                originalQueue = queue
                var remaining = queue
                remaining.remove(at: currentIndex)
                remaining = historyAwareShuffle(remaining)
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
        feedback.light()
        resyncPreloadedItems()
        NotificationCenter.default.post(name: AudioPlayer.shuffleRepeatDidChange, object: nil)
    }

    func clearUpNext() {
        let firstUpcomingIndex = currentIndex + 1
        guard firstUpcomingIndex < queue.count else { return }
        let removed = Array(queue[firstUpcomingIndex...])
        queue.removeSubrange(firstUpcomingIndex...)
        for track in removed {
            if let origIdx = originalQueue.firstIndex(of: track) {
                originalQueue.remove(at: origIdx)
            }
        }
        resyncPreloadedItems()
        feedback.medium()
        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
    }

    func jumpToIndex(_ index: Int) {
        guard index >= 0, index < queue.count else { return }
        checkScrobbleOnSkip()
        feedback.selection()
        loadTrack(at: index)
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
        feedback.light()
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
        let wasEmpty = queue.isEmpty
        let insertIndex = min(currentIndex + 1, queue.count)
        queue.insert(track, at: insertIndex)
        if let current = currentTrack, let origIdx = originalQueue.firstIndex(of: current) {
            originalQueue.insert(track, at: min(origIdx + 1, originalQueue.count))
        } else {
            originalQueue.append(track)
        }
        resyncPreloadedItems()
        feedback.light()
        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
        if wasEmpty {
            NotificationCenter.default.post(name: AudioPlayer.trackDidChange, object: nil)
        }
    }

    func addToQueue(_ track: Track) {
        let wasEmpty = queue.isEmpty
        queue.append(track)
        originalQueue.append(track)
        resyncPreloadedItems()
        feedback.light()
        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
        if wasEmpty {
            NotificationCenter.default.post(name: AudioPlayer.trackDidChange, object: nil)
        }
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
                    self.userPausedPlayback = true
                    self.player?.pause()
                    self.applyPlaybackState(false)
                }
            }
        }
        NotificationCenter.default.post(name: AudioPlayer.sleepTimerDidUpdate, object: nil)
        feedback.light()
    }

    func setSleepTimerEndOfTrack() {
        cancelSleepTimer()
        sleepAtEndOfTrack = true
        NotificationCenter.default.post(name: AudioPlayer.sleepTimerDidUpdate, object: nil)
        feedback.light()
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
        scrobbleAtNaturalEndIfEligible()

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
        scheduleAutoplayContinuationIfNeeded()

        if sleepAtEndOfTrack {
            cancelSleepTimer()
            userPausedPlayback = true
            player?.pause()
            applyPlaybackState(false)
        } else {
            userPausedPlayback = false
            activateSession()
            player?.play()
            isPlaying = true
        }

        updateNowPlayingInfo()
        ensureArtworkLoaded(for: track)
        sendNowPlayingToLastFM(track: track)


        NotificationCenter.default.post(name: AudioPlayer.trackDidChange, object: nil)
        NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
    }

    private func handleQueueExhausted() {
        guard playingItem != nil else { return }
        scrobbleAtNaturalEndIfEligible()
        playingItem = nil
        preloadedItem = nil
        preloadedIndex = nil

        if autoplaySimilarWhenQueueEnds, repeatMode == .off, !sleepAtEndOfTrack {
            AppLogger.info("Queue exhausted at index \(currentIndex), attempting autoplay continuation", category: .playback)
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

    private func finishQueueExhausted() {
        AppLogger.info("Queue exhausted at index \(currentIndex), stopping", category: .playback)
        if sleepAtEndOfTrack {
            cancelSleepTimer()
        }
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
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
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    #if os(macOS)
    private static let volumeDefaultsKey = "flaccy.mac.volume"

    static let volumeDidChange = Notification.Name("PlayerVolumeDidChange")

    /// App-level output volume driving `AVQueuePlayer.volume`, persisted across
    /// launches; the desktop convention, leaving hardware volume untouched.
    var volume: Float {
        get {
            guard UserDefaults.standard.object(forKey: Self.volumeDefaultsKey) != nil else { return 0.8 }
            return min(1, max(0, UserDefaults.standard.float(forKey: Self.volumeDefaultsKey)))
        }
        set {
            let clamped = min(1, max(0, newValue))
            UserDefaults.standard.set(clamped, forKey: Self.volumeDefaultsKey)
            player?.volume = clamped
            NotificationCenter.default.post(name: Self.volumeDidChange, object: nil)
        }
    }
    #endif

    private func removePlayerObservers() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func loadTrack(at index: Int) {
        guard index >= 0, index < queue.count else { return }
        if playbackIsGated() { return }
        currentIndex = index
        userPausedPlayback = false

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
        scheduleAutoplayContinuationIfNeeded()

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

    /// A track that reaches its natural end always counts locally (play count,
    /// Recap stats), but only tracks meeting the Last.fm eligibility rule are
    /// submitted, so sub-30-second interludes are never scrobbled remotely
    /// just because they finished.
    private func scrobbleAtNaturalEndIfEligible() {
        guard !hasScrobbled, let track = currentTrack else { return }
        let eligibleForLastFM = track.duration > 0
            && meetsScrobbleCriteria(elapsed: track.duration, trackDuration: track.duration)
        performScrobble(submitToLastFM: eligibleForLastFM)
    }

    /// Write-ahead persists the scrobble, then flushes through the pending
    /// queue as the single Last.fm submission path, so a foreground or
    /// network-restore retry can never double-submit an in-flight scrobble.
    private func performScrobble(submitToLastFM: Bool = true) {
        guard let track = currentTrack else { return }
        hasScrobbled = true
        let startTime = trackStartTime ?? Date()
        let trackDuration = Int(track.duration)
        let dbID = track.dbID
        let scrobblesToLastFM = submitToLastFM && LastFMService.shared.isAuthenticated
        let record = ScrobbleRecord(
            trackTitle: track.title,
            artist: track.artist,
            albumTitle: track.albumTitle,
            timestamp: startTime,
            duration: trackDuration,
            submitted: !scrobblesToLastFM
        )

        Task { [record, dbID, scrobblesToLastFM] in
            await Task.detached {
                Self.persistScrobble(record, playCountTrackID: dbID)
            }.value
            guard scrobblesToLastFM else { return }
            await self.retryPendingScrobbles()
        }
    }

    /// Bumps the play count and inserts the write-ahead scrobble row off the
    /// main actor so crossing the scrobble threshold never causes a database
    /// hitch mid-playback.
    private nonisolated static func persistScrobble(_ record: ScrobbleRecord, playCountTrackID: Int64?) {
        if let playCountTrackID {
            do {
                try DatabaseManager.shared.incrementPlayCount(trackId: playCountTrackID)
            } catch {
                AppLogger.error("Failed to increment play count: \(error.localizedDescription)", category: .database)
            }
        }
        do {
            try DatabaseManager.shared.insertScrobble(record)
        } catch {
            AppLogger.error("Failed to persist scrobble: \(error.localizedDescription)", category: .database)
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

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            DispatchQueue.main.async {
                guard let self else { return }
                self.seek(to: self.currentTime + interval)
            }
            return .success
        }

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            DispatchQueue.main.async {
                guard let self else { return }
                self.seek(to: max(0, self.currentTime - interval))
            }
            return .success
        }

        center.changeShuffleModeCommand.isEnabled = true
        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let shuffleEvent = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            DispatchQueue.main.async {
                guard let self else { return }
                let wantsShuffle = shuffleEvent.shuffleType != .off
                if wantsShuffle != self.shuffleEnabled { self.toggleShuffle() }
            }
            return .success
        }

        center.changeRepeatModeCommand.isEnabled = true
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let repeatEvent = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            DispatchQueue.main.async {
                guard let self else { return }
                let target: RepeatMode =
                    repeatEvent.repeatType == .all ? .all : repeatEvent.repeatType == .one ? .one : .off
                while self.repeatMode != target { self.cycleRepeatMode() }
            }
            return .success
        }

        center.likeCommand.isEnabled = true
        center.likeCommand.localizedTitle = "Love on Last.fm"
        center.likeCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let track = self.currentTrack else { return }
                Task { _ = await LovedTracksService.shared.toggleLove(track: track) }
            }
            return .success
        }

        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        syncRemoteCommandState()
    }

    /// Keeps the system UI's shuffle/repeat/like toggles showing the app's
    /// actual state (CarPlay and the expanded now-playing controls read these).
    private func syncRemoteCommandState() {
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = shuffleEnabled ? .items : .off
        center.changeRepeatModeCommand.currentRepeatType =
            repeatMode == .all ? .all : repeatMode == .one ? .one : .off
        if let track = currentTrack {
            center.likeCommand.isActive = LovedTracksService.shared.isLoved(track: track)
        }
    }

    private func resolveArtwork(for track: Track) -> PlatformImage? {
        track.artwork ?? AlbumArtworkCache.shared.artwork(forAlbum: track.albumTitle, artist: track.artist)
    }

    private func ensureArtworkLoaded(for track: Track) {
        guard resolveArtwork(for: track) == nil else { return }
        AlbumArtworkCache.shared.loadArtwork(forAlbum: track.albumTitle, artist: track.artist) { [weak self] _ in
            self?.updateNowPlayingInfo()
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
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: currentIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
            MPMediaItemPropertyAlbumTrackNumber: track.trackNumber,
        ]

        if let artwork = resolveArtwork(for: track) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: artwork.size
            ) { _ in artwork }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        syncRemoteCommandState()
    }

    func saveQueueState() {
        guard !(isRestoringQueue && queue.isEmpty) else { return }
        let docsDir = LibraryPaths.root
        let paths = queue.map { relativePath(for: $0, docsDir: docsDir) }
        UserDefaults.standard.set(paths, forKey: "flaccy.queue.paths")
        if shuffleEnabled {
            let originalPaths = originalQueue.map { relativePath(for: $0, docsDir: docsDir) }
            UserDefaults.standard.set(originalPaths, forKey: "flaccy.queue.originalPaths")
        } else {
            UserDefaults.standard.removeObject(forKey: "flaccy.queue.originalPaths")
        }
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

    private func relativePath(for track: Track, docsDir: URL) -> String {
        let trackPath = track.fileURL.standardizedFileURL.path
        let docsPath = docsDir.path
        if trackPath.hasPrefix(docsPath) {
            let rel = String(trackPath.dropFirst(docsPath.count))
            return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        }
        return track.fileURL.lastPathComponent
    }

    /// Reads the persisted queue keys synchronously, then resolves the saved
    /// paths into records off the main actor before hydrating tracks and
    /// rebuilding the paused player, so restoring a long queue never stalls
    /// launch with per-track database reads.
    func restoreQueueState() {
        guard let paths = UserDefaults.standard.stringArray(forKey: "flaccy.queue.paths"),
              !paths.isEmpty else { return }

        let savedIndex = UserDefaults.standard.integer(forKey: "flaccy.queue.index")
        let savedElapsed = UserDefaults.standard.double(forKey: "flaccy.queue.elapsed")
        let savedShuffle = UserDefaults.standard.bool(forKey: "flaccy.queue.shuffle")
        let savedRepeat = UserDefaults.standard.integer(forKey: "flaccy.queue.repeat")
        let savedCurrentPath = UserDefaults.standard.string(forKey: "flaccy.queue.currentPath")
        let savedOriginalPaths = savedShuffle
            ? UserDefaults.standard.stringArray(forKey: "flaccy.queue.originalPaths")
            : nil

        isRestoringQueue = true
        Task { [weak self] in
            let fetched = await Task.detached {
                Self.fetchRestorableRecords(paths: paths, originalPaths: savedOriginalPaths)
            }.value
            defer { self?.isRestoringQueue = false }
            self?.applyRestoredQueue(
                records: fetched.records,
                originalRecords: fetched.originalRecords,
                savedIndex: savedIndex,
                savedElapsed: savedElapsed,
                savedShuffle: savedShuffle,
                savedRepeat: savedRepeat,
                savedCurrentPath: savedCurrentPath
            )
        }
    }

    private nonisolated static func fetchRestorableRecords(
        paths: [String], originalPaths: [String]?
    ) -> (records: [(path: String, record: TrackRecord)], originalRecords: [TrackRecord]?) {
        let records = paths.compactMap { path -> (path: String, record: TrackRecord)? in
            guard let record = try? DatabaseManager.shared.fetchTrack(byRelativePath: path) else { return nil }
            return (path, record)
        }
        let originalRecords = originalPaths?.compactMap {
            try? DatabaseManager.shared.fetchTrack(byRelativePath: $0)
        }
        return (records, originalRecords)
    }

    /// Hydrates a restored record into a Track, resolving artwork once per
    /// album through the shared downsampled cache instead of decoding each
    /// track's embedded cover, so a restored queue never pins duplicate
    /// full-size images.
    private func restoredTrack(from record: TrackRecord, artworkByAlbum: inout [String: PlatformImage?]) -> Track {
        let key = "\(record.albumTitle)|\(record.artist)"
        let artwork: PlatformImage?
        if let cached = artworkByAlbum[key] {
            artwork = cached
        } else {
            artwork = AlbumArtworkCache.shared.artwork(forAlbum: record.albumTitle, artist: record.artist)
            artworkByAlbum[key] = artwork
        }
        return Track.from(record: record, artwork: artwork)
    }

    private func applyRestoredQueue(
        records: [(path: String, record: TrackRecord)],
        originalRecords: [TrackRecord]?,
        savedIndex: Int,
        savedElapsed: Double,
        savedShuffle: Bool,
        savedRepeat: Int,
        savedCurrentPath: String?
    ) {
        guard queue.isEmpty, playingItem == nil else { return }

        var artworkByAlbum: [String: PlatformImage?] = [:]
        var restoredTracks: [Track] = []
        var restoredPaths: [String] = []
        for (path, record) in records {
            restoredTracks.append(restoredTrack(from: record, artworkByAlbum: &artworkByAlbum))
            restoredPaths.append(path)
        }

        guard !restoredTracks.isEmpty else { return }

        queue = restoredTracks
        if let originalRecords, !originalRecords.isEmpty {
            originalQueue = originalRecords.map { restoredTrack(from: $0, artworkByAlbum: &artworkByAlbum) }
        } else {
            originalQueue = restoredTracks
        }

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
        if let track = currentTrack {
            ensureArtworkLoaded(for: track)
        }

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
        userPausedPlayback = true

        if position > 0 {
            let cmTime = CMTime(seconds: position, preferredTimescale: 600)
            player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        startTimeObserver()
        updateNowPlayingInfo()
    }

    /// Builds a station of the seed artist's tracks plus similar-in-library artists
    /// (weighted by match) off the main thread, then plays from the top.
    func startStation(seedArtist: String) {
        guard !isBuildingStation else { return }
        isBuildingStation = true
        let pool = Library.shared.allTracks
        AppLogger.info("Building artist station for \(seedArtist) from \(pool.count) library tracks", category: .playback)
        Task.detached { [weak self] in
            let tracks = await StationBuilder.artistStation(
                seedArtist: seedArtist, pool: pool, excluding: [], limit: StationBuilder.stationSize
            )
            guard let self else { return }
            await MainActor.run { self.startBuiltStation(tracks, seedArtist: seedArtist) }
        }
    }

    /// Builds a station seeded by the track's artist, biased to place the seed track
    /// first; falls back to a plain artist station when similar data is unavailable.
    func startStation(seedTrack: Track) {
        guard !isBuildingStation else { return }
        isBuildingStation = true
        let pool = Library.shared.allTracks
        AppLogger.info("Building track station for \(seedTrack.title) - \(seedTrack.artist)", category: .playback)
        Task.detached { [weak self] in
            let tracks = await StationBuilder.trackStation(
                seedTrack: seedTrack, pool: pool, excluding: [], limit: StationBuilder.stationSize
            )
            guard let self else { return }
            await MainActor.run { self.startBuiltStation(tracks, seedArtist: seedTrack.artist) }
        }
    }

    /// Builds a station from the user's most-played tracks (weighted by scrobble
    /// count) shuffled with variety.
    func playLibraryRadio() {
        guard !isBuildingStation else { return }
        isBuildingStation = true
        let pool = Library.shared.allTracks
        AppLogger.info("Building library radio from \(pool.count) library tracks", category: .playback)
        Task.detached { [weak self] in
            let counts = (try? DatabaseManager.shared.playCountByTrack()) ?? []
            let tracks = StationBuilder.libraryRadio(
                pool: pool, playCounts: counts, excluding: [], limit: StationBuilder.stationSize
            )
            guard let self else { return }
            await MainActor.run { self.startBuiltStation(tracks, seedArtist: nil) }
        }
    }

    private func startBuiltStation(_ tracks: [Track], seedArtist: String?) {
        isBuildingStation = false
        guard !tracks.isEmpty else {
            AppLogger.warning("Station build produced no tracks (seed \(seedArtist ?? "library"))", category: .playback)
            return
        }
        AppLogger.info("Starting station with \(tracks.count) tracks (seed \(seedArtist ?? "library"))", category: .playback)
        play(tracks, startingAt: 0, stationSeed: seedArtist)
    }

    /// Extends the queue ahead of exhaustion so the KVO advance path always has a
    /// next item to preload, keeping continuation gapless.
    private func scheduleAutoplayContinuationIfNeeded() {
        guard autoplaySimilarWhenQueueEnds, !autoplayContinuationInFlight, repeatMode == .off else { return }
        guard !queue.isEmpty, currentIndex >= queue.count - 2 else { return }
        buildAutoplayContinuation(then: nil)
    }

    private func buildAutoplayContinuation(then completion: ((Bool) -> Void)?) {
        guard !autoplayContinuationInFlight else { completion?(false); return }
        autoplayContinuationInFlight = true
        let pool = Library.shared.allTracks
        let existing = Set(queue.map(\.fileURL))
        let seedArtist = stationSeedArtist ?? currentTrack?.artist
        let seedTrack = currentTrack
        Task { [weak self] in
            let batch = await Task.detached { () -> [Track] in
                if let seedArtist {
                    return await StationBuilder.artistStation(
                        seedArtist: seedArtist, pool: pool, excluding: existing, limit: StationBuilder.continuationBatchSize
                    )
                }
                if let seedTrack {
                    return await StationBuilder.trackStation(
                        seedTrack: seedTrack, pool: pool, excluding: existing, limit: StationBuilder.continuationBatchSize
                    )
                }
                let counts = (try? DatabaseManager.shared.playCountByTrack()) ?? []
                return StationBuilder.libraryRadio(
                    pool: pool, playCounts: counts, excluding: existing, limit: StationBuilder.continuationBatchSize
                )
            }.value
            self?.appendContinuation(batch, then: completion)
        }
    }

    private func appendContinuation(_ batch: [Track], then completion: ((Bool) -> Void)?) {
        autoplayContinuationInFlight = false
        let existing = Set(queue.map(\.fileURL))
        let fresh = batch.filter { !existing.contains($0.fileURL) }
        guard !fresh.isEmpty else {
            AppLogger.info("Autoplay continuation produced no new tracks", category: .playback)
            completion?(false)
            return
        }
        queue.append(contentsOf: fresh)
        originalQueue.append(contentsOf: fresh)
        AppLogger.info("Autoplay appended \(fresh.count) continuation tracks (queue now \(queue.count))", category: .playback)
        resyncPreloadedItems()
        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
        completion?(true)
    }

    /// Shuffle that de-weights recently-played tracks using each track's `lastPlayed`
    /// timestamp, so a shuffle surfaces neglected music before recent repeats while
    /// still touching everything.
    private func historyAwareShuffle(_ tracks: [Track]) -> [Track] {
        let weights = recencyWeights()
        return StationBuilder.weightedShuffle(tracks) { weights[$0.fileURL.standardizedFileURL] ?? 1.0 }
    }

    private func recencyWeights() -> [URL: Double] {
        guard let keys = try? DatabaseManager.shared.fetchTrackSortKeys() else { return [:] }
        let docs = LibraryPaths.root
        let now = Date()
        let halfLife: Double = 3 * 24 * 3600
        var map: [URL: Double] = [:]
        for entry in keys {
            let url = docs.appendingPathComponent(entry.fileURL).standardizedFileURL
            guard let lastPlayed = entry.lastPlayed else { map[url] = 1.0; continue }
            let age = max(0, now.timeIntervalSince(lastPlayed))
            map[url] = max(0.05, age / (age + halfLife))
        }
        return map
    }

    /// Drains the pending queue in passes until it is empty or a pass makes no
    /// progress; a call arriving while a pass is already in flight requests a
    /// fresh drain instead of being dropped, so a row persisted mid-pass is
    /// always picked up. All database work runs off the main actor and only
    /// the gating flags stay on it.
    func retryPendingScrobbles() async {
        guard !isRetryingScrobbles else {
            scrobbleRetryRequested = true
            return
        }
        guard LastFMService.shared.isAuthenticated else { return }
        isRetryingScrobbles = true
        defer { isRetryingScrobbles = false }
        repeat {
            scrobbleRetryRequested = false
            await drainPendingScrobblesOnce()
        } while scrobbleRetryRequested
    }

    private func drainPendingScrobblesOnce() async {
        do {
            var pending = try await Task.detached { try Self.retireStaleAndFetchPending() }.value
            while !pending.isEmpty {
                AppLogger.info("Retrying \(pending.count) pending scrobbles", category: .sync)

                let tuples = pending.compactMap { record -> (id: Int64, track: String, artist: String, album: String, timestamp: Date, duration: Int)? in
                    guard let id = record.id else { return nil }
                    return (id: id, track: record.trackTitle, artist: record.artist, album: record.albumTitle, timestamp: record.timestamp, duration: record.duration)
                }
                let submittedIds = await LastFMService.shared.submitPendingScrobbles(scrobbles: tuples)
                AppLogger.info("Scrobble retry: \(submittedIds.count)/\(pending.count) submitted", category: .sync)
                guard !submittedIds.isEmpty else { break }

                pending = try await Task.detached { () throws -> [ScrobbleRecord] in
                    try DatabaseManager.shared.markScrobblesSubmitted(ids: submittedIds)
                    return try DatabaseManager.shared.fetchPendingScrobbles()
                }.value
            }
        } catch {
            AppLogger.error("Scrobble retry failed: \(error.localizedDescription)", category: .sync)
        }
    }

    /// Retires pending scrobbles Last.fm would reject as too old, then returns
    /// the remaining submission backlog; runs off the main actor.
    private nonisolated static func retireStaleAndFetchPending() throws -> [ScrobbleRecord] {
        try DatabaseManager.shared.retirePendingScrobbles(
            olderThan: Date().addingTimeInterval(-14 * 86_400)
        )
        return try DatabaseManager.shared.fetchPendingScrobbles()
    }
}

/// Transport feedback: real haptic generators on iOS, silent on macOS where
/// hover and pressed states carry the same role.
private struct PlaybackFeedback {

    #if os(iOS)
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    #endif

    func light() {
        #if os(iOS)
        impactLight.impactOccurred()
        #endif
    }

    func medium() {
        #if os(iOS)
        impactMedium.impactOccurred()
        #endif
    }

    func selection() {
        #if os(iOS)
        selectionFeedback.selectionChanged()
        #endif
    }
}
