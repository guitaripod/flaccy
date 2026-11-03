import MidgarCore
#if DEBUG
import AppKit
import FlaccyCore
import FlaccyEngine

/// `--shot-song-volume`: plays the equalizer test tone from tmp/eqtest at
/// +3.5 dB, captures the main window with the transport bar's level pill, then
/// the Song Volume popover the presenter hangs from the volume control.
enum DebugSongVolumeShot {

    static func run(window: NSWindow?) async {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("eqtest/eqtest-a.flac")
        let track = Track(
            fileURL: file, title: "Lantern Year", artist: "Ashgrove", albumTitle: "Signal Bloom",
            albumArtist: nil, trackNumber: 1, duration: 40, artwork: nil, dbID: nil
        )
        _ = try? SongVolumeStore.shared.set(35, for: track)
        AudioPlayer.shared.play([track], startingAt: 0)
        try? await Task.sleep(for: .seconds(3))
        DebugDrive.capture(window: window, name: "flaccy-shot-song-volume-window")
        MacSongVolumePresenter.present(for: track)
        try? await Task.sleep(for: .seconds(2))
        capturePopover(MacSongVolumePresenter.shownWindow, name: "flaccy-shot-song-volume-popover")
        if AudioPlayer.shared.isPlaying { AudioPlayer.shared.togglePlayPause() }
        _ = try? SongVolumeStore.shared.set(0, for: track)
        MidgarLog.info("DebugDrive: song volume shot finished", category: .general)
    }

    /// WindowServer hands back an empty picture for a popover's window, so the popover is drawn from its own views.
    private static func capturePopover(_ window: NSWindow?, name: String) {
        guard let data = DebugDrive.cachedDisplayPNG(window) else {
            MidgarLog.error("DebugDrive: no popover to capture for \(name)", category: .general)
            return
        }
        let path = NSTemporaryDirectory() + name + ".png"
        try? data.write(to: URL(fileURLWithPath: path))
        MidgarLog.info("DebugDrive: captured popover to \(path)", category: .general)
    }
}
#endif
