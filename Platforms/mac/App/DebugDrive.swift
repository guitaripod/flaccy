import MidgarCore
#if DEBUG
import AppKit
import FlaccyCore

/// Headless verification harness for development builds: launched with
/// `--exercise-transport`, it waits for the library, then drives the exact
/// code paths the transport bar uses — play, seek, pause, resume, next,
/// window resize — so an agent can validate playback and hunt leaks without
/// clicking. Compiled out of Release entirely.
enum DebugDrive {

    static func runIfRequested(window: NSWindow?) {
        if CommandLine.arguments.contains("--memory-audit") {
            Task { await MemoryAudit.run(window: window) }
        }
        if let layout = value(after: "--detail-layout") {
            UserDefaults.standard.set(layout, forKey: TrackPageSongs.layoutKey)
        }
        DebugStatsDrive.runIfRequested()
        DebugArtworkDrive.runIfRequested(window: window)
        if let target = value(after: "--dump-log") {
            Task {
                try? await Task.sleep(for: .seconds(8))
                dumpLog(to: target)
            }
        }
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
        if CommandLine.arguments.contains("--exercise-songs") {
            Task {
                await exerciseSongs(window: window)
            }
        }
        if CommandLine.arguments.contains("--exercise-import") {
            Task {
                await exerciseFolderImport()
            }
        }
        if CommandLine.arguments.contains("--exercise-zoom") {
            Task {
                await exerciseZoom(window: window)
            }
        }
        if CommandLine.arguments.contains("--exercise-onboarding") {
            Task {
                await exerciseOnboarding(window: window)
            }
        }
        if CommandLine.arguments.contains("--exercise-home") {
            DebugHomeDrive.exercise()
        }
        if CommandLine.arguments.contains("--exercise-stack") {
            Task {
                await exerciseStack(window: window)
            }
        }
        DebugEmbeddedServerDrive.runIfRequested()
        DebugShareLibraryDrive.runIfRequested(window: window)
        ServerSyncExercise.runIfRequested()
        ServerSyncReseedExercise.runIfRequested()
        guard CommandLine.arguments.contains("--exercise-transport") else { return }
        MidgarLog.info("DebugDrive: transport exercise armed", category: .general)
        Task {
            await exercise(window: window)
        }
    }

    enum Shot {
        case section(SidebarSection)
        case album(String)
        case artist(String)
        case onboarding
        case legacyMove
        case nowPlaying
        case playlistDetail(String)
        case nowPlayingLyrics
        case queuePanel(deep: Bool)
        case settings(paneIndex: Int)
        case paywall
        case equalizer(String)
        case stats(ChartPeriod)
        case songs(SongsTableViewModel.Filter, ChartPeriod?)
        case home(String)
    }

    static func plannedShot() -> Shot? {
        if let variant = DebugHomeDrive.variant { return .home(variant) }
        if CommandLine.arguments.contains("--shot-onboarding") { return .onboarding }
        if CommandLine.arguments.contains("--shot-legacy-move") { return .legacyMove }
        if CommandLine.arguments.contains("--shot-paywall") { return .paywall }
        if CommandLine.arguments.contains("--shot-playlists") { return .section(.playlists) }
        if let name = value(after: "--shot-playlist") { return .playlistDetail(name) }
        if CommandLine.arguments.contains("--shot-nowplaying-lyrics") { return .nowPlayingLyrics }
        if CommandLine.arguments.contains("--shot-nowplaying") { return .nowPlaying }
        if CommandLine.arguments.contains("--shot-queue-deep") { return .queuePanel(deep: true) }
        if CommandLine.arguments.contains("--shot-queue") { return .queuePanel(deep: false) }
        if let scene = value(after: "--shot-equalizer") { return .equalizer(scene) }
        if let period = value(after: "--shot-stats") { return .stats(ChartPeriod(rawValue: period) ?? .week) }
        if let filter = value(after: "--shot-songs").flatMap(SongsTableViewModel.Filter.init(rawValue:)) {
            return .songs(filter, value(after: "--songs-range").flatMap(ChartPeriod.init(rawValue:)))
        }
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

    /// Copies the sandboxed file log somewhere a shell can read it — TCC keeps
    /// `~/Library/Containers` closed to Terminal, so headless verification asks
    /// the app to hand its own log out.
    static func dumpLog(to path: String) {
        let destination = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: destination)
        do {
            MidgarLog.flush()
            guard let current = MidgarLog.logFileURLs.first else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.copyItem(at: current, to: destination)
            MidgarLog.info("DebugDrive: log dumped to \(path)", category: .general)
        } catch {
            MidgarLog.error("DebugDrive: log dump failed: \(error.localizedDescription)", category: .general)
        }
    }

    static func value(after flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    static func drive(shot: Shot, window: NSWindow?) async {
        if case .home(let variant) = shot {
            await DebugHomeDrive.run(variant: variant, window: window)
            return
        }
        if case .onboarding = shot {
            try? await Task.sleep(for: .seconds(3))
            capture(window: window, name: "flaccy-shot-onboarding")
            return
        }
        if case .legacyMove = shot {
            try? await Task.sleep(for: .seconds(6))
            captureSheet(of: window, name: "flaccy-shot-legacy-move")
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
                if CommandLine.arguments.contains("--custom-cover") {
                    DebugArtworkDrive.seedCustomCover(forPlaylistNamed: "Late Shift")
                }
            }
            startHeroPlayback()
            try? await Task.sleep(for: .seconds(2))
            NotificationCenter.default.post(
                name: .flaccyShowSection, object: nil,
                userInfo: [SectionNotificationKey.section: section.rawValue]
            )
            name = "flaccy-shot-\(section.title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        case .album(let title):
            startHeroPlayback()
            try? await Task.sleep(for: .seconds(2))
            if let album = Library.shared.albums.first(where: { $0.title == title }) {
                LibraryNavigator.revealAlbum(title: album.title, artist: album.artist)
            } else {
                MidgarLog.error("DebugDrive: album not found: \(title)", category: .general)
            }
            await driveDetailPage(window: window)
            name = "flaccy-shot-album"
        case .artist(let artist):
            startHeroPlayback()
            try? await Task.sleep(for: .seconds(2))
            LibraryNavigator.revealArtist(artist)
            name = "flaccy-shot-artist"
        case .playlistDetail(let playlistName):
            seedDemoPlaylists()
            if CommandLine.arguments.contains("--custom-cover") {
                DebugArtworkDrive.seedCustomCover(forPlaylistNamed: playlistName)
            }
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
                MidgarLog.error("DebugDrive: playlist not found: \(playlistName)", category: .general)
            }
            await driveDetailPage(window: window)
            name = "flaccy-shot-playlist-detail"
        case .nowPlaying:
            startHeroPlayback()
            try? await Task.sleep(for: .seconds(2))
            NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
            name = "flaccy-shot-nowplaying"
        case .nowPlayingLyrics:
            // The panels persist now, so a shot has to state its own starting point.
            NowPlayingLayout.lyricsShown = false
            NowPlayingLayout.queueShown = false
            NowPlayingLayout.swapSides = CommandLine.arguments.contains("--swap")
            if CommandLine.arguments.contains("--deep") { startDeepPlayback() } else { startHeroPlayback() }
            try? await Task.sleep(for: .seconds(2))
            NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
            try? await Task.sleep(for: .seconds(2))
            NotificationCenter.default.post(name: .flaccyToggleLyrics, object: nil)
            NotificationCenter.default.post(name: .flaccyToggleQueue, object: nil)
            try? await Task.sleep(for: .seconds(2))
            name = "flaccy-shot-nowplaying-lyrics"
        case .queuePanel(let deep):
            if deep { startDeepPlayback() } else { startHeroPlayback() }
            try? await Task.sleep(for: .seconds(2))
            NotificationCenter.default.post(name: .flaccyToggleQueue, object: nil)
            name = deep ? "flaccy-shot-queue-deep" : "flaccy-shot-queue"
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
        case .equalizer(let scene):
            let engine = EqualizerEngine.shared
            engine.start()
            engine.isDemoSignal = true
            let isSimple = scene != "advanced"
            engine.seedDemo(
                activeProfileID: isSimple ? EqualizerPresets.id(forKey: "rock") : "demo.warm",
                pretendOutput: EqualizerOutput(
                    id: isSimple ? "builtin.speaker.demo" : "bluetooth.demo",
                    name: isSimple ? "MacBook Pro Speakers" : "AirPods Pro",
                    kind: isSimple ? .speaker : .bluetooth
                )
            )
            let controller = MacEqualizerWindowController.shared
            controller.show()
            controller.window?.setContentSize(NSSize(width: 1280 * MacInterfaceScale.current, height: 760 * MacInterfaceScale.current))
            reassertWindowSizeIfRequested(controller.window)
            controller.window?.center()
            if scene == "hover", let screen = controller.contentViewController as? MacEqualizerViewController {
                await exerciseDeck(screen, engine: engine)
            }
            try? await Task.sleep(for: .seconds(3))
            if scene == "presets", let screen = controller.contentViewController as? MacEqualizerViewController {
                screen.auditionForCapture(profileID: EqualizerPresets.id(forKey: "bassBoost"))
                try? await Task.sleep(for: .seconds(1))
            }
            capture(window: controller.window, name: "flaccy-shot-equalizer-\(scene)")
            return
        case .stats(let period):
            await seedRecentListeningIfRequested()
            NotificationCenter.default.post(
                name: .flaccyShowSection, object: nil,
                userInfo: [SectionNotificationKey.section: SidebarSection.charts.rawValue]
            )
            try? await Task.sleep(for: .seconds(3))
            if let charts: ChartsViewController = findController(in: window?.contentViewController) {
                charts.selectPeriodForCapture(period)
            }
            try? await Task.sleep(for: .seconds(3))
            if CommandLine.arguments.contains("--scroll-bottom"),
               let charts: ChartsViewController = findController(in: window?.contentViewController) {
                charts.scrollToBottomForCapture()
                try? await Task.sleep(for: .seconds(1))
            }
            name = "flaccy-shot-stats-\(period.rawValue)"
        case .songs(let filter, let range):
            await seedRecentListeningIfRequested()
            NotificationCenter.default.post(
                name: .flaccyShowSection, object: nil,
                userInfo: [SectionNotificationKey.section: SidebarSection.songs.rawValue]
            )
            try? await Task.sleep(for: .seconds(3))
            if let songs: SongsTableViewController = findController(in: window?.contentViewController) {
                songs.selectFilterForCapture(filter, range: range)
            }
            try? await Task.sleep(for: .seconds(2))
            name = "flaccy-shot-songs-\(filter.rawValue)"
        case .paywall:
            (NSApp.delegate as? MacAppDelegate)?.presentPaywall()
            try? await Task.sleep(for: .seconds(3))
            captureSheet(of: window, name: "flaccy-shot-paywall")
            return
        case .onboarding, .home:
            return
        case .legacyMove:
            return
        }
        try? await Task.sleep(for: .seconds(3))
        reassertWindowSizeIfRequested(window)
        try? await Task.sleep(for: .seconds(1))
        capture(window: window, name: name)
        if let size = value(after: "--resize-after") {
            resize(window, to: size)
            try? await Task.sleep(for: .seconds(3))
            capture(window: window, name: name + "-resized")
        }
    }

    static func resize(_ window: NSWindow?, to size: String) {
        let parts = size.lowercased().split(separator: "x")
        guard let window, parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { return }
        window.setContentSize(NSSize(width: width, height: height))
    }

}
#endif
