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
        if CommandLine.arguments.contains("--exercise-stack") {
            Task {
                await exerciseStack(window: window)
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
        case nowPlaying
        case playlistDetail(String)
        case nowPlayingLyrics
        case queuePanel
        case settings(paneIndex: Int)
    }

    private static func plannedShot() -> Shot? {
        if CommandLine.arguments.contains("--shot-onboarding") { return .onboarding }
        if CommandLine.arguments.contains("--shot-playlists") { return .section(.playlists) }
        if let name = value(after: "--shot-playlist") { return .playlistDetail(name) }
        if CommandLine.arguments.contains("--shot-nowplaying-lyrics") { return .nowPlayingLyrics }
        if CommandLine.arguments.contains("--shot-nowplaying") { return .nowPlaying }
        if CommandLine.arguments.contains("--shot-queue") { return .queuePanel }
        if let pane = value(after: "--shot-settings") { return .settings(paneIndex: Int(pane) ?? 0) }
        if let name = value(after: "--shot-section") {
            let section: SidebarSection? = switch name {
            case "albums": .albums
            case "songs": .songs
            case "artists": .artists
            case "playlists": .playlists
            case "wantlist": .wantlist
            case "charts": .charts
            case "yearinmusic": .yearInMusic
            case "guide": .listeningGuide
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
            if section == .playlists {
                seedDemoPlaylists()
                startHeroPlayback()
                try? await Task.sleep(for: .seconds(2))
            }
            NotificationCenter.default.post(
                name: .flaccyShowSection, object: nil,
                userInfo: [SectionNotificationKey.section: section.rawValue]
            )
            name = "flaccy-shot-\(section.title.lowercased().replacingOccurrences(of: " ", with: "-"))"
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
        case .playlistDetail(let playlistName):
            seedDemoPlaylists()
            startHeroPlayback()
            try? await Task.sleep(for: .seconds(2))
            NotificationCenter.default.post(
                name: .flaccyShowSection, object: nil,
                userInfo: [SectionNotificationKey.section: SidebarSection.playlists.rawValue]
            )
            try? await Task.sleep(for: .seconds(1))
            if let record = try? DatabaseManager.shared.fetchAllPlaylists()
                .first(where: { $0.name == playlistName }) {
                findStack(window: window)?.push(PlaylistDetailViewController(playlist: record))
            } else {
                AppLogger.error("DebugDrive: playlist not found: \(playlistName)", category: .general)
            }
            name = "flaccy-shot-playlist-detail"
        case .nowPlaying:
            startHeroPlayback()
            try? await Task.sleep(for: .seconds(2))
            NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
            name = "flaccy-shot-nowplaying"
        case .nowPlayingLyrics:
            startHeroPlayback()
            try? await Task.sleep(for: .seconds(2))
            NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
            try? await Task.sleep(for: .seconds(2))
            NotificationCenter.default.post(name: .flaccyToggleLyrics, object: nil)
            name = "flaccy-shot-nowplaying-lyrics"
        case .queuePanel:
            startHeroPlayback()
            try? await Task.sleep(for: .seconds(2))
            NotificationCenter.default.post(name: .flaccyToggleQueue, object: nil)
            name = "flaccy-shot-queue"
        case .settings(let paneIndex):
            NSApp.delegate?.perform(NSSelectorFromString("showSettings:"), with: nil)
            try? await Task.sleep(for: .seconds(2))
            let settingsWindow = NSApp.windows.first {
                $0.contentViewController is SettingsTabViewController
            }
            if let tabs = settingsWindow?.contentViewController as? SettingsTabViewController {
                tabs.selectedTabViewItemIndex = paneIndex
            }
            try? await Task.sleep(for: .seconds(3))
            capture(window: settingsWindow, name: "flaccy-shot-settings-\(paneIndex)")
            return
        case .onboarding:
            return
        }
        try? await Task.sleep(for: .seconds(3))
        reassertWindowSizeIfRequested(window)
        try? await Task.sleep(for: .seconds(1))
        capture(window: window, name: name)
    }

    /// Section switches can shrink the window below the requested capture
    /// size; re-apply the `--window-size` content size right before capture.
    private static func reassertWindowSizeIfRequested(_ window: NSWindow?) {
        guard let window,
              let index = CommandLine.arguments.firstIndex(of: "--window-size"),
              index + 1 < CommandLine.arguments.count else { return }
        let parts = CommandLine.arguments[index + 1].lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { return }
        window.setContentSize(NSSize(width: width, height: height))
    }

    /// Seeds two populated playlists from the fictional catalog so the
    /// Playlists screenshot never renders an empty state. Idempotent.
    private static func seedDemoPlaylists() {
        let plans: [(name: String, picks: [(String, Int)])] = [
            ("Night Drive", [("Parallax Hours", 1), ("Signal Bloom", 3), ("Cassini", 0),
                             ("Midnatt", 0), ("Aurorae", 1), ("Paper Cities", 0)]),
            ("Sunday Slow", [("Tradewinds", 0), ("Ember & Ash", 4), ("Lantern Year", 1),
                             ("Ravine", 1), ("Aurorae", 4)]),
        ]
        do {
            let existing = try DatabaseManager.shared.fetchAllPlaylists().map(\.name)
            for plan in plans where !existing.contains(plan.name) {
                let playlist = try DatabaseManager.shared.createPlaylist(name: plan.name)
                guard let playlistId = playlist.id else { continue }
                let tracks = plan.picks.compactMap { title, index -> Track? in
                    guard let album = Library.shared.albums.first(where: { $0.title == title }),
                          album.tracks.indices.contains(index) else { return nil }
                    return album.tracks[index]
                }
                PlaylistActions.add(tracks, toPlaylist: playlistId, named: plan.name, in: nil)
            }
        } catch {
            AppLogger.error("DebugDrive: playlist seeding failed: \(error.localizedDescription)", category: .general)
        }
    }

    /// Pops mid-push at varying offsets inside the 240ms slide animation to
    /// prove overlapping transitions can never leave the section root hidden.
    private static func exerciseStack(window: NSWindow?) async {
        var attempts = 0
        while Library.shared.albums.isEmpty, attempts < 40 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        try? await Task.sleep(for: .seconds(1))
        guard let album = Library.shared.albums.first else {
            AppLogger.error("DebugDrive: no album for stack exercise", category: .general)
            return
        }
        for delayMs in [20, 60, 120, 180, 230, 300] {
            LibraryNavigator.revealAlbum(title: album.title, artist: album.artist)
            try? await Task.sleep(for: .milliseconds(delayMs))
            findStack(window: window)?.pop()
            try? await Task.sleep(for: .milliseconds(delayMs))
        }
        LibraryNavigator.revealAlbum(title: album.title, artist: album.artist)
        try? await Task.sleep(for: .milliseconds(100))
        findStack(window: window)?.popToRoot()
        try? await Task.sleep(for: .seconds(1))
        guard let stack = findStack(window: window), let root = stack.stack.first else {
            AppLogger.error("DebugDrive: stack exercise found no ContentStackController", category: .general)
            return
        }
        AppLogger.info(
            "DebugDrive: stack exercise complete — depth \(stack.stack.count), rootHidden=\(root.view.isHidden), rootAlpha=\(root.view.alphaValue)",
            category: .general
        )
    }

    private static func findStack(window: NSWindow?) -> ContentStackController? {
        guard let root = window?.contentViewController else { return nil }
        return descendToStack(root)
    }

    private static func descendToStack(_ controller: NSViewController) -> ContentStackController? {
        if let stack = controller as? ContentStackController { return stack }
        for child in controller.children {
            if let stack = descendToStack(child) { return stack }
        }
        return nil
    }

    private static func startHeroPlayback() {
        let hero = Library.shared.albums.first { $0.title == "Parallax Hours" } ?? Library.shared.albums.first
        guard let hero, !hero.tracks.isEmpty else {
            AppLogger.error("DebugDrive: no album available for hero playback", category: .general)
            return
        }
        AudioPlayer.shared.volume = 0.02
        let index = hero.tracks.firstIndex { $0.title == "Slow Machine" } ?? 0
        AudioPlayer.shared.play(hero.tracks, startingAt: index)
        AudioPlayer.shared.seek(to: 58)
    }

    private static func capture(window: NSWindow?, name: String) {
        if let window {
            AppLogger.info(
                "DebugDrive: capture \(name) — frame \(window.frame), screen \(window.screen?.frame ?? .zero), backingScale \(window.backingScaleFactor)",
                category: .general
            )
        }
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
        guard let data = windowServerPNG(window) ?? cachedDisplayPNG(window) else {
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

    private typealias SLSMainConnectionIDFunc = @convention(c) () -> Int32
    private typealias SLSHWCaptureWindowListFunc = @convention(c) (
        Int32, UnsafeMutablePointer<UInt32>, Int32, UInt32
    ) -> Unmanaged<CFArray>?

    /// Captures the window as composited by WindowServer (glass, vibrancy and
    /// shadows render for real), which works without Screen Recording TCC for
    /// windows the process itself owns. Uses SkyLight SPI, which is fine here:
    /// this is a DEBUG-only screenshot rig that never ships in Release.
    private static func windowServerPNG(_ window: NSWindow?) -> Data? {
        guard let window, window.windowNumber > 0,
              let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connectionSymbol = dlsym(skyLight, "SLSMainConnectionID"),
              let captureSymbol = dlsym(skyLight, "SLSHWCaptureWindowList")
        else { return nil }
        let mainConnection = unsafeBitCast(connectionSymbol, to: SLSMainConnectionIDFunc.self)
        let captureWindows = unsafeBitCast(captureSymbol, to: SLSHWCaptureWindowListFunc.self)
        var windowID = UInt32(window.windowNumber)
        let ignoreClipShapeAndBestResolution: UInt32 = (1 << 11) | (1 << 8)
        guard let images = captureWindows(
                  mainConnection(), &windowID, 1, ignoreClipShapeAndBestResolution
              )?.takeRetainedValue() as? [CGImage],
              let image = images.first, image.width > 1
        else {
            AppLogger.error("DebugDrive: WindowServer capture unavailable, falling back to cacheDisplay", category: .general)
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
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
