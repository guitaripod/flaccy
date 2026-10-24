import Foundation

/// Which Now Playing panels are open and which side each one sits on, kept
/// across launches the way the Linux client keeps `np_show_lyrics`,
/// `np_show_queue` and `np_swap_sides`. View configuration only: the queue
/// contents and playback position are session restore, a separate thing.
enum NowPlayingLayout {

    private static let lyricsKey = "flaccy.mac.nowPlaying.lyricsShown"
    private static let queueKey = "flaccy.mac.nowPlaying.queueShown"
    private static let swapKey = "flaccy.mac.nowPlaying.swapSides"

    static var lyricsShown: Bool {
        get { UserDefaults.standard.bool(forKey: lyricsKey) }
        set { UserDefaults.standard.set(newValue, forKey: lyricsKey) }
    }

    static var queueShown: Bool {
        get { UserDefaults.standard.bool(forKey: queueKey) }
        set { UserDefaults.standard.set(newValue, forKey: queueKey) }
    }

    static var swapSides: Bool {
        get { UserDefaults.standard.bool(forKey: swapKey) }
        set { UserDefaults.standard.set(newValue, forKey: swapKey) }
    }
}
