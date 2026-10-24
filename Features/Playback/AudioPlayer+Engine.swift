import AVFoundation
import FlaccyCore

extension AudioPlayer {

    var queue: [Track] { engine.queue }
    var currentIndex: Int { engine.currentIndex }
    var isPlaying: Bool { engine.isPlaying }
    var currentTrack: Track? { engine.currentTrack }
    var currentTime: TimeInterval { engine.currentTime }
    var duration: TimeInterval { engine.duration }
    var shuffleEnabled: Bool { engine.shuffleEnabled }
    var repeatMode: RepeatMode { engine.repeatMode }
    var sleepTimerRemaining: TimeInterval? { engine.sleepTimerRemaining }
    var sleepAtEndOfTrack: Bool { engine.sleepAtEndOfTrack }

    var autoplaySimilarWhenQueueEnds: Bool {
        get { engine.autoplaySimilarWhenQueueEnds }
        set { engine.autoplaySimilarWhenQueueEnds = newValue }
    }

    #if os(macOS)
    var volume: Float {
        get { engine.volume }
        set { engine.volume = newValue }
    }
    #endif

    func play(_ tracks: [Track], startingAt index: Int) { engine.play(tracks, startingAt: index) }
    func togglePlayPause() { engine.togglePlayPause() }
    func nextTrack() { engine.nextTrack() }
    func previousTrack() { engine.previousTrack() }
    func seek(to time: TimeInterval) { engine.seek(to: time) }

    func seekSmooth(to time: CMTime, tolerance: CMTime, completion: @escaping @MainActor () -> Void) {
        engine.seekSmooth(to: time, tolerance: tolerance, completion: completion)
    }

    func toggleShuffle() { engine.toggleShuffle() }
    func cycleRepeatMode() { engine.cycleRepeatMode() }
    func clearUpNext() { engine.clearUpNext() }
    func jumpToIndex(_ index: Int) { engine.jumpToIndex(index) }
    func removeFromQueue(at index: Int) { engine.removeFromQueue(at: index) }
    func handleDeletedTracks(_ urls: Set<URL>) { engine.handleDeletedTracks(urls) }

    func moveInQueue(from sourceIndex: Int, to destinationIndex: Int) {
        engine.moveInQueue(from: sourceIndex, to: destinationIndex)
    }

    func insertNext(_ track: Track) { engine.insertNext(track) }
    func addToQueue(_ track: Track) { engine.addToQueue(track) }
    func setSleepTimer(minutes: Int) { engine.setSleepTimer(minutes: minutes) }
    func setSleepTimerEndOfTrack() { engine.setSleepTimerEndOfTrack() }
    func cancelSleepTimer() { engine.cancelSleepTimer() }
    func saveQueueState() { engine.saveQueueState() }
    func restoreQueueState() { engine.restoreQueueState() }
}
