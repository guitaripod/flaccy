import MidgarCore
#if DEBUG
import AppKit
import FlaccyCore

extension DebugDrive {

    /// Opens Now Playing with its lyrics, then the Meaning popover on line
    /// `line` (`--shot-lyric-meaning <index>`) or on the whole song
    /// (`--shot-lyric-meaning song`), waits for Wikipedia and the AI, and
    /// captures the window and the popover's own window.
    static func driveLyricMeaning(window: NSWindow?, line: Int?) async {
        NowPlayingLayout.lyricsShown = false
        NowPlayingLayout.queueShown = false
        guard let hero = Library.shared.albums.first(where: { $0.title == "Parallax Hours" }),
              let index = hero.tracks.firstIndex(where: { $0.title == "Slow Machine" })
        else {
            MidgarLog.error("DebugDrive: lyric meaning needs the seeded Slow Machine", category: .general)
            return
        }
        AudioPlayer.shared.volume = 0.02
        AudioPlayer.shared.autoplaySimilarWhenQueueEnds = false
        AudioPlayer.shared.play([hero.tracks[index]], startingAt: 0)
        try? await Task.sleep(for: .seconds(1))
        if AudioPlayer.shared.isPlaying { AudioPlayer.shared.togglePlayPause() }
        NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
        try? await Task.sleep(for: .seconds(2))
        NotificationCenter.default.post(name: .flaccyToggleLyrics, object: nil)
        try? await Task.sleep(for: .seconds(2))
        let nowPlaying: NowPlayingViewController? = findController(in: window?.contentViewController)
        guard let panel = nowPlaying?.lyricsPanel else {
            MidgarLog.error("DebugDrive: lyric meaning found no Now Playing lyrics panel", category: .general)
            return
        }
        var shown: NSPopover?
        for _ in 0..<30 where shown == nil {
            shown = panel.showMeaning(line: line)
            if shown == nil { try? await Task.sleep(for: .milliseconds(500)) }
        }
        guard let popover = shown else {
            MidgarLog.error(
                "DebugDrive: lyric meaning has nothing to explain at line \(String(describing: line)) of \(AudioPlayer.shared.currentTrack?.title ?? "no track")",
                category: .general)
            return
        }
        try? await Task.sleep(for: .seconds(15))
        let meaning = popover.contentViewController as? MacLyricsMeaningViewController
        MidgarLog.info("DebugDrive: lyric meaning state \(meaning?.captureState ?? "none")", category: .general)
        capture(window: window, name: "flaccy-shot-lyric-meaning")
        capture(window: popover.contentViewController?.view.window, name: "flaccy-shot-lyric-meaning-popover")
    }
}
#endif
