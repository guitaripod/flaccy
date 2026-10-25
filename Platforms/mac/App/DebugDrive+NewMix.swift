import MidgarCore
#if DEBUG
import AppKit
import FlaccyCore

extension DebugDrive {

    /// Seeds one re-exported song and captures the windows that show the New
    /// mix chip, one picture each for the album page, Now Playing with the
    /// lyrics and queue columns closed, and the queue column. Launch with
    /// `--shot-new-mix`; the pictures land in the app's temporary folder.
    static func runNewMixShotIfRequested(window: NSWindow?) {
        guard CommandLine.arguments.contains(ReexportExercise.shotArgument) else { return }
        Task {
            guard let track = await ReexportExercise.seedRevisedSong() else { return }
            AudioPlayer.shared.volume = 0.02
            AudioPlayer.shared.play([track], startingAt: 0)
            try? await Task.sleep(for: .seconds(2))
            LibraryNavigator.revealAlbum(title: track.albumTitle, artist: track.artist)
            await driveDetailPage(window: window)
            try? await Task.sleep(for: .seconds(2))
            capture(window: window, name: "flaccy-new-mix-album")
            NowPlayingLayout.lyricsShown = false
            NowPlayingLayout.queueShown = false
            NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
            try? await Task.sleep(for: .seconds(3))
            capture(window: window, name: "flaccy-new-mix-nowplaying")
            NotificationCenter.default.post(name: .flaccyToggleQueue, object: nil)
            try? await Task.sleep(for: .seconds(3))
            capture(window: window, name: "flaccy-new-mix-queue")
            MidgarLog.info("NEW MIX SHOT CAPTURED", category: .general)
        }
    }
}
#endif
