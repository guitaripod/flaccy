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
                capture(window: window, name: "flaccy-window")
            }
        }
        if let shot = plannedShot() {
            Task {
                await drive(shot: shot, window: window)
            }
        }
        if CommandLine.arguments.contains("--exercise-library") {
            Task {
                await exerciseLibrary(window: window)
            }
        }
        guard CommandLine.arguments.contains("--exercise-transport") else { return }
        AppLogger.info("DebugDrive: transport exercise armed", category: .general)
        Task {
            await exercise(window: window)
        }
    }

    private enum Shot {
        case section(SidebarSection)
        case album(String)
        case artist(String)
        case onboarding
    }

    private static func plannedShot() -> Shot? {
        if CommandLine.arguments.contains("--shot-onboarding") { return .onboarding }
        if CommandLine.arguments.contains("--shot-playlists") { return .section(.playlists) }
        if let name = value(after: "--shot-section") {
            let section: SidebarSection? = switch name {
            case "albums": .albums
            case "songs": .songs
            case "artists": .artists
            case "playlists": .playlists
            default: nil
            }
            if let section { return .section(section) }
        }
        if let title = value(after: "--shot-album") { return .album(title) }
        if let artist = value(after: "--shot-artist") { return .artist(artist) }
        return nil
    }

    private static func value(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private static func drive(shot: Shot, window: NSWindow?) async {
        if case .onboarding = shot {
            try? await Task.sleep(for: .seconds(3))
            capture(window: window, name: "flaccy-shot-onboarding")
            return
        }
        var attempts = 0
        while Library.shared.albums.isEmpty, attempts < 40 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        try? await Task.sleep(for: .seconds(1))
        let name: String
        switch shot {
        case .section(let section):
            NotificationCenter.default.post(
                name: .flaccyShowSection, object: nil,
                userInfo: [SectionNotificationKey.section: section.rawValue]
            )
            name = "flaccy-shot-\(section.title.lowercased())"
        case .album(let title):
            if let album = Library.shared.albums.first(where: { $0.title == title }) {
                LibraryNavigator.revealAlbum(title: album.title, artist: album.artist)
            } else {
                AppLogger.error("DebugDrive: album not found: \(title)", category: .general)
            }
            name = "flaccy-shot-album"
        case .artist(let artist):
            LibraryNavigator.revealArtist(artist)
            name = "flaccy-shot-artist"
        case .onboarding:
            return
        }
        try? await Task.sleep(for: .seconds(3))
        capture(window: window, name: name)
    }

    private static func capture(window: NSWindow?, name: String) {
        if let root = window?.contentViewController as? RootContainerViewController {
            let sidebar = root.splitViewController.sidebarViewController
            AppLogger.info("DebugDrive: sidebar renders \(sidebar.visibleRowCount) rows", category: .general)
        }
        if let contentView = window?.contentView,
           let tree = contentView.perform(NSSelectorFromString("_subtreeDescription"))?.takeUnretainedValue() as? String {
            let treePath = NSTemporaryDirectory() + "flaccy-viewtree.txt"
            try? tree.write(to: URL(fileURLWithPath: treePath), atomically: true, encoding: .utf8)
            AppLogger.info("DebugDrive: view tree dumped to \(treePath)", category: .general)
        }
        guard let data = cachedDisplayPNG(window) else {
            AppLogger.error("DebugDrive: no capture path produced an image", category: .general)
            return
        }
        let path = NSTemporaryDirectory() + name + ".png"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            AppLogger.info("DebugDrive: captured window to \(path)", category: .general)
        } catch {
            AppLogger.error("DebugDrive: window capture failed: \(error.localizedDescription)", category: .general)
        }
    }

    private static func cachedDisplayPNG(_ window: NSWindow?) -> Data? {
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// Drives the exact code paths behind the library UI — play from the
    /// grid, Play Next, Add to Queue, playlist create/add/reorder/remove and
    /// the drag-drop import — and logs each result for headless verification.
    private static func exerciseLibrary(window: NSWindow?) async {
        AudioPlayer.shared.volume = 0.05
        var attempts = 0
        while Library.shared.albums.isEmpty, attempts < 40 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        let albums = Library.shared.albums
        guard albums.count >= 2, let first = albums.first, let second = albums.dropFirst().first else {
            AppLogger.error("DebugDrive: need 2+ albums to exercise library", category: .general)
            return
        }

        AudioPlayer.shared.play(first.tracks, startingAt: 0)
        try? await Task.sleep(for: .seconds(1))
        AppLogger.info(
            "DebugDrive: grid play — now \(AudioPlayer.shared.currentTrack?.title ?? "none"), queue \(AudioPlayer.shared.queue.count)",
            category: .general
        )

        if let next = second.tracks.first {
            AudioPlayer.shared.insertNext(next)
            AppLogger.info("DebugDrive: Play Next inserted \(next.title), queue \(AudioPlayer.shared.queue.count)", category: .general)
        }
        if let queued = second.tracks.last {
            AudioPlayer.shared.addToQueue(queued)
            AppLogger.info("DebugDrive: Add to Queue appended \(queued.title), queue \(AudioPlayer.shared.queue.count)", category: .general)
        }

        do {
            let playlist = try DatabaseManager.shared.createPlaylist(name: "DebugDrive Mix")
            guard let playlistId = playlist.id else { return }
            PlaylistActions.add(Array(first.tracks.prefix(3)), toPlaylist: playlistId, named: playlist.name, in: window)
            var records = try DatabaseManager.shared.fetchPlaylistTracks(playlistId: playlistId)
            AppLogger.info("DebugDrive: playlist has \(records.count) rows", category: .general)
            records.reverse()
            PlaylistActions.persistOrder(records)
            let reordered = try DatabaseManager.shared.fetchPlaylistTracks(playlistId: playlistId)
            AppLogger.info(
                "DebugDrive: reorder check — first row now \(reordered.first?.trackFileURL ?? "none")",
                category: .general
            )
            if let victim = reordered.first?.id {
                try DatabaseManager.shared.removeTrackFromPlaylist(id: victim)
                let remaining = try DatabaseManager.shared.fetchPlaylistTracks(playlistId: playlistId)
                AppLogger.info("DebugDrive: row removed, \(remaining.count) remain", category: .general)
            }
            try DatabaseManager.shared.deletePlaylist(id: playlistId)
            AppLogger.info("DebugDrive: playlist deleted", category: .general)
        } catch {
            AppLogger.error("DebugDrive: playlist exercise failed: \(error.localizedDescription)", category: .general)
        }

        if let sourceTrack = second.tracks.first {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("DebugDriveImport", isDirectory: true)
            let stagedFile = staging.appendingPathComponent("Debug Drive Import.flac")
            do {
                try? FileManager.default.removeItem(at: staging)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: sourceTrack.fileURL, to: stagedFile)
                let before = Library.shared.allTracks.count
                await Library.shared.importFiles(from: [stagedFile])
                let after = Library.shared.allTracks.count
                AppLogger.info("DebugDrive: drop import — tracks \(before) → \(after)", category: .general)
                try? FileManager.default.removeItem(at: staging)
            } catch {
                AppLogger.error("DebugDrive: import exercise failed: \(error.localizedDescription)", category: .general)
            }
        }
        AppLogger.info("DebugDrive: library exercise complete", category: .general)
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
