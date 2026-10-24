import AVFoundation
import MidgarCore
import FlaccyCore

/// The platform-neutral playback engine: queue, shuffle and repeat, the
/// AVQueuePlayer and its preloaded next item for gapless advance, sleep
/// timer, queue persistence and autoplay continuation. Everything that
/// touches the app (Now Playing, remote commands, the trial gate, scrobbling,
/// the equalizer, haptics, library artwork) goes through `PlaybackEngineHost`.
@MainActor
public final class PlaybackEngine {

    public static let playbackStateDidChange = Notification.Name("com.midgarcorp.flaccy.PlaybackStateDidChange")
    public static let trackDidChange = Notification.Name("com.midgarcorp.flaccy.TrackDidChange")
    public static let playbackProgressDidChange = Notification.Name("com.midgarcorp.flaccy.PlaybackProgressDidChange")
    public static let shuffleRepeatDidChange = Notification.Name("com.midgarcorp.flaccy.ShuffleRepeatDidChange")
    public static let queueDidChange = Notification.Name("com.midgarcorp.flaccy.QueueDidChange")
    public static let sleepTimerDidUpdate = Notification.Name("com.midgarcorp.flaccy.SleepTimerDidUpdate")

    var player: AVQueuePlayer?
    var timeObserver: Any?
    var timeControlObservation: NSKeyValueObservation?
    var currentItemObservation: NSKeyValueObservation?
    var playingItem: AVPlayerItem?
    var preloadedItem: AVPlayerItem?
    var preloadedIndex: Int?

    var sleepTimer: Timer?
    public internal(set) var sleepTimerRemaining: TimeInterval?
    public internal(set) var sleepAtEndOfTrack = false

    var originalQueue: [Track] = []
    var lastKnownPlaybackPosition: TimeInterval = 0
    var isRestoringQueue: Bool = false
    var wasPlayingBeforeInterruption = false
    var userPausedPlayback = false

    public internal(set) var queue: [Track] = []
    public internal(set) var currentIndex: Int = 0
    public internal(set) var isPlaying: Bool = false
    public internal(set) var shuffleEnabled: Bool = false
    public internal(set) var repeatMode: RepeatMode = .off

    let autoplayDefaultsKey = "flaccy.autoplaySimilarWhenQueueEnds"
    var stationSeedArtist: String?
    var autoplayContinuationInFlight = false
    /// How many tracks from the end the similar-music continuation starts building.
    /// A station pass scans the whole library and reads play counts, so on a large
    /// library two tracks of runway can expire before the queue drains — and the
    /// exhaustion fallback only runs once the audio has already stopped.
    static let autoplayContinuationLookahead = 3
    var pendingQueueExhaustion = false

    public weak var host: (any PlaybackEngineHost)?

    public var continuationBuilder: ContinuationBuilder = { _ in [] }

    /// When enabled, an exhausted queue is extended with a similar-artist / most-played
    /// continuation instead of stopping, so music never just ends. Persisted; default on.
    public var autoplaySimilarWhenQueueEnds: Bool {
        get { UserDefaults.standard.object(forKey: autoplayDefaultsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: autoplayDefaultsKey)
            MidgarLog.info("Autoplay similar when queue ends set to \(newValue)", category: .playback)
        }
    }

    public var currentTrack: Track? {
        guard !queue.isEmpty, currentIndex >= 0, currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    /// Reads off `playingItem` rather than the queue player so the value never
    /// jumps to the preloaded next item during the auto-advance window, where
    /// `player.currentItem` has already switched but bookkeeping hasn't.
    public var currentTime: TimeInterval {
        guard let item = playingItem ?? player?.currentItem else { return 0 }
        let t = CMTimeGetSeconds(item.currentTime())
        return t.isFinite && t >= 0 ? t : 0
    }

    /// Anchored to `playingItem` for the same auto-advance-race reason as
    /// `currentTime`, and falls back to the track's metadata duration while the
    /// asset is still loading (an unresolved AVPlayerItem reports indefinite),
    /// so the timeline never shows a stale or zero total.
    public var duration: TimeInterval {
        if let item = playingItem ?? player?.currentItem {
            let d = CMTimeGetSeconds(item.duration)
            if d.isFinite, d > 0 { return d }
        }
        return currentTrack?.duration ?? 0
    }

    public init() {
        registerPlayerItemObservers()
        #if os(iOS)
        registerAudioSessionObservers()
        #endif
    }

    private func registerPlayerItemObservers() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleItemFailedToPlayToEnd(_:)), name: .AVPlayerItemFailedToPlayToEndTime, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleItemDidPlayToEnd(_:)), name: .AVPlayerItemDidPlayToEndTime, object: nil
        )
    }

    func applyPlaybackState(_ playing: Bool) {
        isPlaying = playing
        host?.playbackStateDidUpdate()
        postOnMain(PlaybackEngine.playbackStateDidChange)
    }

    /// Delivers every state notification on the main thread. AVFoundation
    /// delivers KVO and seek/end callbacks on internal CoreMedia queues, so a
    /// synchronous post from there would call AppKit observers (menu bar,
    /// transport, now playing) off the main thread and crash.
    func postOnMain(_ name: Notification.Name) {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: name, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: name, object: nil)
            }
        }
    }

    func playbackIsGated() -> Bool {
        host?.isPlaybackGated() ?? false
    }

    public func play(_ tracks: [Track], startingAt index: Int) {
        play(tracks, startingAt: index, stationSeed: nil)
    }

    /// Every queue replacement flows through here so the autoplay-continuation
    /// seed is deterministically set for stations and cleared for ordinary
    /// plays, never leaking a stale station artist into unrelated listening.
    public func play(_ tracks: [Track], startingAt index: Int, stationSeed: String?) {
        guard !tracks.isEmpty, index >= 0, index < tracks.count else { return }
        if playbackIsGated() { return }
        stationSeedArtist = stationSeed
        host?.trackWillBeSkipped()
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
        host?.playFeedback(.medium)
        loadTrack(at: currentIndex)
        postOnMain(PlaybackEngine.queueDidChange)
    }

    public func togglePlayPause() {
        wasPlayingBeforeInterruption = false
        guard let player else {
            if playbackIsGated() { return }
            if queue.indices.contains(currentIndex) {
                host?.playFeedback(.light)
                loadTrack(at: currentIndex)
            }
            return
        }
        host?.playFeedback(.light)
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
            host?.activateAudioSession()
            player.play()
        }
        applyPlaybackState(!isPlaying)
    }

    public func nextTrack() {
        host?.trackWillBeSkipped()
        guard currentIndex + 1 < queue.count else {
            if repeatMode == .all && !queue.isEmpty {
                host?.playFeedback(.selection)
                loadTrack(at: 0)
            } else {
                player?.pause()
                applyPlaybackState(false)
            }
            return
        }
        host?.playFeedback(.selection)
        loadTrack(at: currentIndex + 1)
    }

    public func previousTrack() {
        if currentTime > 3 {
            host?.playFeedback(.selection)
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    self?.host?.playbackStateDidUpdate()
                    self?.postOnMain(PlaybackEngine.playbackProgressDidChange)
                }
            }
            return
        }
        host?.trackWillBeSkipped()
        guard currentIndex > 0 else {
            player?.seek(to: .zero)
            return
        }
        host?.playFeedback(.selection)
        loadTrack(at: currentIndex - 1)
    }

    public func seek(to time: TimeInterval) {
        guard let player, player.currentItem === playingItem else { return }
        let cmTime = CMTime(seconds: clampedSeekTarget(time), preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.host?.playbackStateDidUpdate()
                self?.postOnMain(PlaybackEngine.playbackProgressDidChange)
            }
        }
    }

    public func seekSmooth(to time: CMTime, tolerance: CMTime, completion: @escaping @MainActor () -> Void) {
        guard let player, player.currentItem === playingItem else {
            completion()
            return
        }
        let target = CMTime(seconds: clampedSeekTarget(CMTimeGetSeconds(time)), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            Task { @MainActor in
                if finished {
                    self?.host?.playbackStateDidUpdate()
                }
                completion()
            }
        }
    }

    /// Keeps every seek inside the real item bounds, stopping a hair short of
    /// the end so a scrub released at 100% plays out naturally instead of
    /// slamming item-end and force-advancing the queue mid-gesture.
    func clampedSeekTarget(_ time: TimeInterval) -> TimeInterval {
        let total = duration
        guard total > 0 else { return max(0, time) }
        return min(max(0, time), max(0, total - 0.25))
    }
}
