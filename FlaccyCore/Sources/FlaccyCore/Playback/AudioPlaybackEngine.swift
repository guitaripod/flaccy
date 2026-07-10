import Foundation

/// Platform-agnostic contract for a queue-based audio player.
///
/// The iOS `AudioPlayer` and the watchOS `WatchAudioPlayer` both fulfill this
/// shape; UI layers and view models program against the protocol.
@MainActor
public protocol AudioPlaybackEngine: AnyObject {
    var queue: [MediaItem] { get }
    var currentIndex: Int { get }
    var isPlaying: Bool { get }
    var currentItem: MediaItem? { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    var repeatMode: RepeatMode { get }
    var shuffleEnabled: Bool { get }

    func play(_ items: [MediaItem], startingAt index: Int)
    func togglePlayPause()
    func next()
    func previous()
    func seek(to time: TimeInterval)
    func toggleShuffle()
    func cycleRepeatMode()
}

public extension AudioPlaybackEngine {
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }
}
