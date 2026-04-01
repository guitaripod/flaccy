import AVFoundation
import MediaPlayer
import UIKit

nonisolated enum RepeatMode: Sendable {
    case off
    case all
    case one
}

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
    func setSleepTimer(minutes: Int)
    func cancelSleepTimer()
}

final class AudioPlayer: AudioPlaying {

    static let shared: AudioPlaying = AudioPlayer()

    static let playbackStateDidChange = Notification.Name("PlaybackStateDidChange")
    static let trackDidChange = Notification.Name("TrackDidChange")
    static let playbackProgressDidChange = Notification.Name("PlaybackProgressDidChange")
    static let shuffleRepeatDidChange = Notification.Name("ShuffleRepeatDidChange")
    static let queueDidChange = Notification.Name("QueueDidChange")

    private var player: AVQueuePlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback = UISelectionFeedbackGenerator()

    private var sleepTimer: Timer?
    private(set) var sleepTimerRemaining: TimeInterval?

    private var trackStartTime: Date?
    private var hasScrobbled: Bool = false
    private var originalQueue: [Track] = []

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
            self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            if isPlaying {
                player?.pause()
                isPlaying = false
                updateNowPlayingInfo()
                NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
            }
        case .ended:
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    player?.play()
                    isPlaying = true
                    updateNowPlayingInfo()
                    NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
                }
            }
        @unknown default:
            break
        }
    }

    func play(_ tracks: [Track], startingAt index: Int) {
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
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
        impactLight.impactOccurred()
        updateNowPlayingInfo()
        NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
    }

    func nextTrack() {
        checkScrobbleOnSkip()
        if repeatMode == .one {
            loadTrack(at: currentIndex)
            return
        }
        guard currentIndex + 1 < queue.count else {
            if repeatMode == .all && !queue.isEmpty {
                currentIndex = 0
                selectionFeedback.selectionChanged()
                loadTrack(at: currentIndex)
            } else {
                player?.pause()
                isPlaying = false
                updateNowPlayingInfo()
                NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
            }
            return
        }
        currentIndex += 1
        selectionFeedback.selectionChanged()
        loadTrack(at: currentIndex)
    }

    func previousTrack() {
        if currentTime > 3 {
            player?.seek(to: .zero)
            selectionFeedback.selectionChanged()
            updateNowPlayingInfo()
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
            NotificationCenter.default.post(name: AudioPlayer.playbackProgressDidChange, object: nil)
        }
    }

    func seekSmooth(to time: CMTime, tolerance: CMTime, completion: @escaping () -> Void) {
        player?.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            if finished {
                self?.updateNowPlayingInfo()
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
        NotificationCenter.default.post(name: AudioPlayer.shuffleRepeatDidChange, object: nil)
    }

    func clearQueue() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        isPlaying = false
        queue = []
        originalQueue = []
        currentIndex = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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
        impactLight.impactOccurred()
        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
    }

    func moveInQueue(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != currentIndex else { return }
        let track = queue.remove(at: sourceIndex)
        queue.insert(track, at: destinationIndex)

        if sourceIndex == currentIndex {
            currentIndex = destinationIndex
        } else if sourceIndex < currentIndex && destinationIndex >= currentIndex {
            currentIndex -= 1
        } else if sourceIndex > currentIndex && destinationIndex <= currentIndex {
            currentIndex += 1
        }

        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
    }

    func insertNext(_ track: Track) {
        let insertIndex = currentIndex + 1
        queue.insert(track, at: min(insertIndex, queue.count))
        originalQueue.append(track)
        impactLight.impactOccurred()
        NotificationCenter.default.post(name: AudioPlayer.queueDidChange, object: nil)
    }

    func addToQueue(_ track: Track) {
        queue.append(track)
        originalQueue.append(track)
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
                if remaining <= 1 {
                    self.cancelSleepTimer()
                    self.player?.pause()
                    self.isPlaying = false
                    self.updateNowPlayingInfo()
                    NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
                }
            }
        }
        impactLight.impactOccurred()
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerRemaining = nil
    }

    private func loadTrack(at index: Int) {
        guard index >= 0, index < queue.count else { return }

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }

        let track = queue[index]
        let item = AVPlayerItem(url: track.fileURL)

        if player == nil {
            player = AVQueuePlayer(items: [item])
        } else {
            player?.removeAllItems()
            player?.insert(item, after: nil)
        }

        preloadNextItem(after: index)

        player?.play()
        isPlaying = true

        trackStartTime = Date()
        hasScrobbled = false

        startTimeObserver()

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.handleTrackFinished()
        }

        AppLogger.info("Now playing: \(track.title) - \(track.artist)", category: .content)
        updateNowPlayingInfo()
        sendNowPlayingToLastFM(track: track)
        NotificationCenter.default.post(name: AudioPlayer.trackDidChange, object: nil)
        NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
    }

    private func preloadNextItem(after index: Int) {
        let nextIndex: Int
        if index + 1 < queue.count {
            nextIndex = index + 1
        } else if repeatMode == .all && !queue.isEmpty {
            nextIndex = 0
        } else {
            return
        }
        let nextItem = AVPlayerItem(url: queue[nextIndex].fileURL)
        if player?.canInsert(nextItem, after: player?.items().last) == true {
            player?.insert(nextItem, after: player?.items().last)
        }
    }

    private func startTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.checkScrobbleCriteria()
            NotificationCenter.default.post(name: AudioPlayer.playbackProgressDidChange, object: nil)
        }
    }

    private func handleTrackFinished() {
        if !hasScrobbled {
            performScrobble()
        }

        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }

        if repeatMode == .one {
            loadTrack(at: currentIndex)
            return
        }

        if currentIndex + 1 < queue.count {
            currentIndex += 1
            trackStartTime = Date()
            hasScrobbled = false

            let track = queue[currentIndex]
            if let currentItem = player?.currentItem {
                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: currentItem, queue: .main
                ) { [weak self] _ in
                    self?.handleTrackFinished()
                }
            }

            preloadNextItem(after: currentIndex)
            AppLogger.info("Gapless advance: \(track.title) - \(track.artist)", category: .content)
            updateNowPlayingInfo()
            sendNowPlayingToLastFM(track: track)
            NotificationCenter.default.post(name: AudioPlayer.trackDidChange, object: nil)
        } else if repeatMode == .all && !queue.isEmpty {
            currentIndex = 0
            loadTrack(at: currentIndex)
        } else {
            player?.pause()
            isPlaying = false
            updateNowPlayingInfo()
            NotificationCenter.default.post(name: AudioPlayer.playbackStateDidChange, object: nil)
        }
    }

    private func checkScrobbleOnSkip() {
        guard !hasScrobbled, currentTrack != nil, duration > 0 else { return }
        let elapsed = currentTime
        if meetsScrobbleCriteria(elapsed: elapsed, trackDuration: duration) {
            performScrobble()
        }
    }

    private func checkScrobbleCriteria() {
        guard !hasScrobbled, currentTrack != nil, duration > 0 else { return }
        let elapsed = currentTime
        if meetsScrobbleCriteria(elapsed: elapsed, trackDuration: duration) {
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
        let trackDuration = Int(duration)

        if let dbID = track.dbID {
            do {
                try DatabaseManager.shared.incrementPlayCount(trackId: dbID)
            } catch {
                AppLogger.error("Failed to increment play count: \(error.localizedDescription)", category: .database)
            }
        }

        Task { [track, startTime, trackDuration] in
            let success = await LastFMService.shared.scrobble(
                track: track.title,
                artist: track.artist,
                album: track.albumTitle,
                timestamp: startTime,
                duration: trackDuration
            )

            if !success {
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
                    AppLogger.info("Saved pending scrobble: \(track.title)", category: .sync)
                } catch {
                    AppLogger.error("Failed to save pending scrobble: \(error.localizedDescription)", category: .database)
                }
            }
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
            self?.nextTrack()
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previousTrack()
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
        guard let track = currentTrack else {
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

        if let artwork = track.artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: artwork.size
            ) { _ in artwork }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
