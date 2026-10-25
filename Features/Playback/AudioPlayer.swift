import AVFoundation
import MidgarCore
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
    func playCrateDig()
    var playbackContext: PlaybackContext { get }
    var resumePoint: ResumePoint? { get }
    func play(_ tracks: [Track], startingAt index: Int)
    func play(_ tracks: [Track], startingAt index: Int, context: PlaybackContext?)
    func togglePlayPause()
    func nextTrack()
    func previousTrack()
    func seek(to time: TimeInterval)
    func toggleShuffle()
    func cycleRepeatMode()
    func clearUpNext()
    func seekSmooth(to time: CMTime, tolerance: CMTime, completion: @escaping @MainActor () -> Void)
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

    static let playbackStateDidChange = PlaybackEngine.playbackStateDidChange
    static let trackDidChange = PlaybackEngine.trackDidChange
    static let playbackProgressDidChange = PlaybackEngine.playbackProgressDidChange
    static let shuffleRepeatDidChange = PlaybackEngine.shuffleRepeatDidChange
    static let queueDidChange = PlaybackEngine.queueDidChange
    static let sleepTimerDidUpdate = PlaybackEngine.sleepTimerDidUpdate
    #if os(macOS)
    static let volumeDidChange = PlaybackEngine.volumeDidChange
    #endif

    let engine = PlaybackEngine()
    let feedback = PlaybackFeedback()

    var trackStartTime: Date?
    var hasScrobbled: Bool = false
    var isRetryingScrobbles: Bool = false
    var scrobbleRetryRequested: Bool = false
    var wasNetworkAvailable: Bool = false
    let pathMonitor = NWPathMonitor()

    var isBuildingStation = false
    /// Sticky cover for the current track so pause/progress Now Playing refreshes
    /// never publish a dictionary without artwork (NSCache eviction / brief load
    /// races otherwise blank the lock-screen and Dynamic Island art).
    var nowPlayingArtworkImage: PlatformImage?
    var nowPlayingArtworkKey: String?

    private init() {
        engine.host = self
        engine.continuationBuilder = { request in await AudioPlayer.continuationBatch(request) }
        configureRemoteCommands()
        registerLifecycleObservers()
        registerServiceObservers()
        startNetworkMonitoring()
    }

    private func registerLifecycleObservers() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillResignActive), name: UIApplication.willResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleLibraryRootChanged), name: LibraryRoot.didChange, object: nil
        )
        #endif
    }

    private func registerServiceObservers() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleLastFMAuthChange), name: LastFMService.authDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleLovedTracksDidChange), name: LovedTracksService.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleArtworkDidChange), name: AlbumArtworkCache.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTracksRevised(_:)), name: Library.tracksRevised, object: nil
        )
    }

    /// Reloads the lock-screen and Control Center cover when the person swaps
    /// the artwork of the album that is playing.
    @objc func handleArtworkDidChange() {
        guard let track = currentTrack else { return }
        nowPlayingArtworkKey = nil
        ensureArtworkLoaded(for: track)
    }

    /// Keeps the system Now Playing heart (lock screen / Dynamic Island) in
    /// sync when love is toggled from anywhere — remote command, in-app, etc.
    @objc func handleLovedTracksDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.syncRemoteCommandState()
        }
    }

    /// Retries pending scrobbles whenever connectivity is restored, so plays queued offline are submitted without waiting for the next app launch.
    func startNetworkMonitoring() {
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

    @objc func handleWillResignActive() {
        engine.saveQueueState()
    }

    /// Connecting flushes anything queued while offline; disconnecting retires
    /// the pending queue so plays stay as local history and nothing waits on an
    /// account the user opted out of.
    @objc func handleLastFMAuthChange() {
        if LastFMService.shared.isAuthenticated {
            Task { await retryPendingScrobbles() }
        } else {
            do {
                try DatabaseManager.shared.retirePendingScrobbles(olderThan: .distantFuture)
            } catch {
                MidgarLog.error("Failed to retire pending scrobbles on disconnect: \(error.localizedDescription)", category: .database)
            }
        }
    }

    @objc func handleWillEnterForeground() {
        Task { await retryPendingScrobbles() }
    }

    #if os(macOS)
    /// Changing the library root revokes the old folder's sandbox extension,
    /// so every queued URL becomes unopenable; tearing the queue down through
    /// the deleted-tracks path stops playback cleanly instead of dying at the
    /// next track boundary.
    @objc func handleLibraryRootChanged() {
        guard !engine.queue.isEmpty else { return }
        MidgarLog.info("Library root changed; clearing playback queue of \(engine.queue.count) tracks", category: .playback)
        engine.handleDeletedTracks(Set(engine.queue.map(\.fileURL)))
    }
    #endif
}
