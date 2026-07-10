#if DEBUG
import AppKit

/// Headless verification harness for development builds: launched with
/// `--exercise-transport`, it waits for the library, then drives the exact
/// code paths the transport bar uses — play, seek, pause, resume, next,
/// window resize — so an agent can validate playback and hunt leaks without
/// clicking. Compiled out of Release entirely.
enum DebugDrive {

    static func runIfRequested(window: NSWindow?) {
        if CommandLine.arguments.contains("--capture-window") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                capture(window: window)
            }
        }
        guard CommandLine.arguments.contains("--exercise-transport") else { return }
        AppLogger.info("DebugDrive: transport exercise armed", category: .general)
        Task {
            await exercise(window: window)
        }
    }

    private static func capture(window: NSWindow?) {
        if let root = window?.contentViewController as? RootContainerViewController {
            let sidebar = root.splitViewController.sidebarViewController
            AppLogger.info("DebugDrive: sidebar renders \(sidebar.visibleRowCount) rows", category: .general)
        }
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let path = NSTemporaryDirectory() + "flaccy-window.png"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            AppLogger.info("DebugDrive: captured window to \(path)", category: .general)
        } catch {
            AppLogger.error("DebugDrive: window capture failed: \(error.localizedDescription)", category: .general)
        }
    }

    private static func exercise(window: NSWindow?) async {
        AudioPlayer.shared.volume = 0.05
        var attempts = 0
        while Library.shared.albums.isEmpty, attempts < 40 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        guard let album = Library.shared.albums.first, !album.tracks.isEmpty else {
            AppLogger.error("DebugDrive: no albums to exercise", category: .general)
            return
        }
        AppLogger.info("DebugDrive: playing \(album.title) — \(album.artist)", category: .general)
        AudioPlayer.shared.play(album.tracks, startingAt: 0)

        try? await Task.sleep(for: .seconds(2))
        AppLogger.info("DebugDrive: seek to 20s (playing: \(AudioPlayer.shared.isPlaying))", category: .general)
        AudioPlayer.shared.seek(to: 20)

        try? await Task.sleep(for: .seconds(1))
        AppLogger.info("DebugDrive: pause", category: .general)
        AudioPlayer.shared.togglePlayPause()

        try? await Task.sleep(for: .seconds(1))
        AppLogger.info("DebugDrive: resume", category: .general)
        AudioPlayer.shared.togglePlayPause()

        try? await Task.sleep(for: .seconds(1))
        AppLogger.info("DebugDrive: next track", category: .general)
        AudioPlayer.shared.nextTrack()

        try? await Task.sleep(for: .seconds(1))
        if let window {
            let frame = window.frame
            window.setFrame(
                NSRect(x: frame.minX, y: frame.minY, width: frame.width + 80, height: frame.height + 40),
                display: true, animate: false
            )
            try? await Task.sleep(for: .milliseconds(500))
            window.setFrame(frame, display: true, animate: false)
        }
        AppLogger.info(
            "DebugDrive: exercise complete (playing: \(AudioPlayer.shared.isPlaying), track: \(AudioPlayer.shared.currentTrack?.title ?? "none"), time: \(AudioPlayer.shared.currentTime))",
            category: .general
        )
    }
}
#endif
