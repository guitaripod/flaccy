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
        if CommandLine.arguments.contains("--exercise-stack") {
            Task {
                await exerciseStack(window: window)
            }
        }
        guard CommandLine.arguments.contains("--exercise-transport") else { return }
        MidgarLog.info("DebugDrive: transport exercise armed", category: .general)
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
        case queuePanel(deep: Bool)
        case settings(paneIndex: Int)
        case paywall
        case equalizer(String)
        case stats(ChartPeriod)
        case songs(SongsTableViewModel.Filter, ChartPeriod?)
    }

    private static func plannedShot() -> Shot? {
        if CommandLine.arguments.contains("--shot-onboarding") { return .onboarding }
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
    private static func dumpLog(to path: String) {
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
        case .onboarding:
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

    private static func resize(_ window: NSWindow?, to size: String) {
        let parts = size.lowercased().split(separator: "x")
        guard let window, parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { return }
        window.setContentSize(NSSize(width: width, height: height))
    }

    /// Applies the `--detail-*` arguments to the album or playlist page that is
    /// on screen: a filter, a table sort, a song playing from the page, a jump
    /// to the playing song and a timing of every layout switch.
    private static func driveDetailPage(window: NSWindow?) async {
        try? await Task.sleep(for: .seconds(2))
        let root = window?.contentViewController
        let album: AlbumDetailViewController? = findController(in: root)
        let playlist: PlaylistDetailViewController? = findController(in: root)
        guard let songs = album?.debugSongs ?? playlist?.debugSongs else {
            MidgarLog.error("DebugDrive: no song page on screen", category: .general)
            return
        }
        if let index = value(after: "--detail-play").flatMap(Int.init), songs.model.entries.indices.contains(index) {
            AudioPlayer.shared.volume = 0.02
            AudioPlayer.shared.play(songs.model.entries.map(\.track), startingAt: index)
            try? await Task.sleep(for: .seconds(1))
        }
        if let text = value(after: "--detail-filter") {
            songs.debugFilter(text)
            try? await Task.sleep(for: .seconds(1))
        }
        if let sort = value(after: "--detail-sort") {
            let parts = sort.split(separator: ":").map(String.init)
            songs.debugSort(column: parts[0], ascending: parts.count < 2 || parts[1] != "desc")
            try? await Task.sleep(for: .seconds(1))
        }
        if CommandLine.arguments.contains("--detail-exercise-layouts") {
            await exerciseLayoutSwitching(songs)
        }
        if CommandLine.arguments.contains("--detail-exercise-playlist") {
            await exercisePlaylistEditing(songs)
        }
        if CommandLine.arguments.contains("--detail-bench") {
            await benchmarkLayouts(songs, window: window)
        }
        if CommandLine.arguments.contains("--detail-locate") {
            window?.contentView?.layoutSubtreeIfNeeded()
            songs.locatePlaying()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Switches layouts through the segmented control's own action and logs
    /// whether the choice is remembered, shared across kinds, resolved for a
    /// playlist without being overwritten, and snaps the page to the top.
    private static func exerciseLayoutSwitching(_ songs: TrackPageSongs) async {
        func report(_ expectation: String, _ passed: Bool) {
            MidgarLog.info("DetailExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .general)
        }
        let key = TrackPageSongs.layoutKey
        for layout in TrackPageLayout.Layout.allCases where layout.isOffered(on: songs.model.kind) {
            let changes = songs.layout != layout
            songs.debugScroll(to: 300)
            try? await Task.sleep(for: .milliseconds(300))
            songs.debugPick(layout)
            try? await Task.sleep(for: .milliseconds(600))
            report("picking \(layout.id) stores it (stored \(UserDefaults.standard.string(forKey: key) ?? "nil"))",
                   UserDefaults.standard.string(forKey: key) == layout.id && songs.layout == layout)
            report("picking \(layout.id) \(changes ? "scrolls to the top" : "again leaves the page alone") (offset \(songs.debugScrollOffset ?? -1))",
                   changes ? abs(songs.debugScrollOffset ?? -1) < 1 : (songs.debugScrollOffset ?? 0) > 1)
        }
        UserDefaults.standard.set("columns", forKey: key)
        let resolved = TrackPageSongs.savedLayout(for: .playlist)
        report("a remembered columns resolves to list for a playlist (got \(resolved.id)) and stays stored",
               resolved == .list && UserDefaults.standard.string(forKey: key) == "columns")
        report("a remembered columns stays columns for an album",
               TrackPageSongs.savedLayout(for: .album) == .columns)
    }

    /// Reorders and removes rows through the same closures a drag and the
    /// context menu call, then reads the page back from the database it
    /// reloads from, and logs PASS or FAIL for each.
    private static func exercisePlaylistEditing(_ songs: TrackPageSongs) async {
        func titles() -> [String] { songs.model.entries.prefix(4).map(\.track.title) }
        func report(_ expectation: String, _ passed: Bool) {
            MidgarLog.info("DetailExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .general)
        }
        let before = titles()
        let count = songs.model.entries.count
        songs.model.reorder?(IndexSet(integer: 0), 3)
        try? await Task.sleep(for: .seconds(1))
        let expected = [before[1], before[2], before[0], before[3]]
        report("moving row 1 below row 3 gives \(expected) (got \(titles()))", titles() == expected)
        songs.model.reorder?(IndexSet([1, 2]), 0)
        try? await Task.sleep(for: .seconds(1))
        let both = [expected[1], expected[2], expected[0], expected[3]]
        report("moving rows 2 and 3 to the top gives \(both) (got \(titles()))", titles() == both)
        if let first = songs.model.entries.first {
            songs.model.remove?([first])
            try? await Task.sleep(for: .seconds(1))
            report("removing the first row leaves \(count - 1) rows (got \(songs.model.entries.count))",
                   songs.model.entries.count == count - 1 && songs.model.entries.first?.track.title == both[1])
        }
    }

    private static func benchmarkLayouts(_ songs: TrackPageSongs, window: NSWindow?) async {
        func milliseconds(_ label: String, _ work: () -> Void) {
            let start = CFAbsoluteTimeGetCurrent()
            work()
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.contentView?.displayIfNeeded()
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            MidgarLog.info("DebugDrive: \(label) took \(elapsed) ms for \(songs.model.entries.count) songs", category: .general)
        }
        for layout in TrackPageLayout.Layout.allCases where layout.isOffered(on: songs.model.kind) {
            milliseconds("layout \(layout.id)") { songs.debugChoose(layout) }
            milliseconds("filter on \(layout.id)") { songs.debugFilter("song 99") }
            milliseconds("filter cleared on \(layout.id)") { songs.debugFilter("") }
        }
        milliseconds("sort by title") { songs.debugChoose(.table); songs.debugSort(column: "title", ascending: false) }
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
    static func seedDemoPlaylists() {
        let plans: [(name: String, picks: [(String, Int)])] = [
            ("Night Drive", [("Parallax Hours", 1), ("Signal Bloom", 3), ("Cassini", 0),
                             ("Midnatt", 0), ("Aurorae", 1), ("Paper Cities", 0), ("Almagest", 0), ("Nightglow", 1)]),
            ("Sunday Slow", [("Tradewinds", 0), ("Ember & Ash", 4), ("Lantern Year", 1),
                             ("Ravine", 1), ("Aurorae", 4), ("Ledger of Small Hours", 3), ("Saltwater Gospel", 4)]),
            ("Deep Focus", [("Tidal Glass", 0), ("Overwinter", 0), ("Field Lines", 0), ("Vantablack Sun", 2),
                            ("Aurorae", 2), ("Midnatt", 1)]),
            ("Golden Hour", [("Greenhouse Hymns", 0), ("Velvet Arithmetic", 0), ("Cassini", 1),
                             ("Saltwater Gospel", 0), ("Paper Cities", 1), ("Southern Cross", 0)]),
            ("Lossless Showcase", [("Parallax Hours", 5), ("Field Lines", 3), ("Vantablack Sun", 0),
                                   ("Southern Cross", 2), ("Almagest", 3), ("Tidal Glass", 2)]),
            ("Rainy Windows", [("Radio Silence", 0), ("Statuary", 1), ("Longshore Drift", 0),
                               ("Ember & Ash", 2), ("Paper Cities", 4)]),
            ("Late Shift", [("Signal Bloom", 0), ("Nightglow", 0), ("Almagest", 2), ("Field Lines", 3),
                            ("Midnatt", 3)]),
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
            MidgarLog.error("DebugDrive: playlist seeding failed: \(error.localizedDescription)", category: .general)
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
            MidgarLog.error("DebugDrive: no album for stack exercise", category: .general)
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
            MidgarLog.error("DebugDrive: stack exercise found no ContentStackController", category: .general)
            return
        }
        MidgarLog.info(
            "DebugDrive: stack exercise complete — depth \(stack.stack.count), rootHidden=\(root.view.isHidden), rootAlpha=\(root.view.alphaValue)",
            category: .general
        )
    }

    /// Drives the Songs table the way a person would: pivots to a chip that
    /// hides the playing song, asks to jump to it (once with a search also
    /// hiding it), and saves the visible list as a playlist, logging PASS or
    /// FAIL for each expectation.
    private static func exerciseSongs(window: NSWindow?) async {
        let resultsURL = URL(fileURLWithPath: NSTemporaryDirectory() + "songs-exercise.txt")
        try? "".write(to: resultsURL, atomically: true, encoding: .utf8)
        func report(_ expectation: String, _ passed: Bool) {
            let line = "SongsExercise \(passed ? "PASS" : "FAIL"): \(expectation)"
            MidgarLog.info(line, category: .general)
            let existing = (try? String(contentsOf: resultsURL, encoding: .utf8)) ?? ""
            try? (existing + line + "\n").write(to: resultsURL, atomically: true, encoding: .utf8)
        }
        var attempts = 0
        while Library.shared.albums.isEmpty, attempts < 40 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        await seedRecentListeningIfRequested()
        startHeroPlayback()
        try? await Task.sleep(for: .seconds(2))
        guard let playing = AudioPlayer.shared.currentTrack?.fileURL.path else {
            report("a song is playing", false)
            return
        }
        NotificationCenter.default.post(
            name: .flaccyShowSection, object: nil,
            userInfo: [SectionNotificationKey.section: SidebarSection.songs.rawValue]
        )
        try? await Task.sleep(for: .seconds(3))
        guard let songs: SongsTableViewController = findController(in: window?.contentViewController) else {
            report("the songs table is on screen", false)
            return
        }
        let pivots: [(SongsTableViewModel.Filter, ChartPeriod?)] = [
            (.favorites, nil), (.rediscover, nil), (.mostPlayed, .week), (.recentlyPlayed, nil), (.lossless, nil),
        ]
        var hidden = false
        for (filter, range) in pivots {
            songs.selectFilterForCapture(filter, range: range)
            try? await Task.sleep(for: .seconds(1))
            if !songs.visibleTrackPathsForExercise.contains(playing) {
                hidden = true
                break
            }
        }
        report("a chip hides the playing song (\(songs.filterForExercise.rawValue))", hidden)

        (NSApp.delegate as? MacAppDelegate)?.jumpToCurrentSong(nil)
        try? await Task.sleep(for: .seconds(2))
        report("jump switches the chip to All", songs.filterForExercise == .all)
        report("jump selects the playing song's row", songs.selectedTrackPathForExercise == playing)

        LibrarySearchState.update("zzzz-no-such-song")
        try? await Task.sleep(for: .seconds(1))
        report("a search that matches nothing empties the list", songs.visibleTrackPathsForExercise.isEmpty)
        (NSApp.delegate as? MacAppDelegate)?.jumpToCurrentSong(nil)
        try? await Task.sleep(for: .seconds(2))
        report("jump clears the search that hid the song", LibrarySearchState.query.isEmpty)
        report("jump selects the row after clearing the search", songs.selectedTrackPathForExercise == playing)

        songs.selectFilterForCapture(.recentlyAdded, range: nil)
        try? await Task.sleep(for: .seconds(1))
        let visible = songs.visibleTrackPathsForExercise
        let tracks = Library.shared.allTracks
        let ordered = visible.compactMap { path in tracks.first { $0.fileURL.path == path } }
        if let playlist = try? DatabaseManager.shared.createPlaylist(name: "Exercise \(UUID().uuidString.prefix(6))"),
           let id = playlist.id {
            PlaylistActions.add(ordered, toPlaylist: id, named: playlist.name, in: nil)
            let saved = (try? DatabaseManager.shared.fetchPlaylistTracks(playlistId: id)) ?? []
            let savedPaths = saved.sorted { $0.position < $1.position }.map(\.trackFileURL)
            let expected = ordered.map { LibraryPathResolver.relativePath(for: $0.fileURL) }
            report("saving \(ordered.count) visible songs keeps their order", savedPaths == expected && !expected.isEmpty)
        } else {
            report("a playlist can be created", false)
        }
        report("status line reads \(songs.statusLineForExercise)", !songs.statusLineForExercise.isEmpty)
        report("done", true)
    }

    private static func seedRecentListeningIfRequested() async {
        guard DebugStatsDrive.wantsRecentListening else { return }
        await DebugStatsDrive.seedRecentListening()
    }

    private static func findController<T: NSViewController>(in root: NSViewController?) -> T? {
        guard let root else { return nil }
        if let match = root as? T { return match }
        for child in root.children {
            if let match: T = findController(in: child) { return match }
        }
        return nil
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

    /// Steps the interface scale through its whole range and back while a song
    /// plays, the way a held ⌘= does, and logs PASS if the window survives it.
    /// Clicks the welcome panel's two buttons the way a reviewer would and logs
    /// whether each click lands on its button and reaches its action. Run it on
    /// an empty library: an invisible view above the panel once took every click.
    private static func exerciseOnboarding(window: NSWindow?) async {
        guard let window, let content = window.contentView, let frameView = content.superview else { return }
        func buttons(in view: NSView) -> [GlassCapsuleButton] {
            (view as? GlassCapsuleButton).map { [$0] } ?? view.subviews.flatMap(buttons(in:))
        }
        func report(_ expectation: String, _ passed: Bool) {
            MidgarLog.info("OnboardingExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .general)
        }
        func chain(of view: NSView?) -> String {
            var names: [String] = []
            var current = view
            while let node = current, names.count < 8 {
                names.append(String(describing: type(of: node)))
                current = node.superview
            }
            return names.joined(separator: " < ")
        }
        func center(of button: GlassCapsuleButton) -> NSPoint {
            button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        }
        func click(_ button: GlassCapsuleButton) {
            window.makeKeyAndOrderFront(nil)
            let point = center(of: button)
            guard let target = frameView.hitTest(point) else { return }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
                ) else { continue }
                if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
            }
        }
        func clickAndWatch(_ button: GlassCapsuleButton) async -> Bool {
            var fired = false
            let original = button.onClick
            button.onClick = {
                fired = true
                original?()
            }
            click(button)
            try? await Task.sleep(for: .milliseconds(800))
            button.onClick = original
            return fired
        }

        let titles = [String(localized: "Choose Music Folder…"), String(localized: "Download Sample Album")]
        var found: [GlassCapsuleButton] = []
        for _ in 0..<40 {
            found = buttons(in: content).filter { titles.contains($0.title) }
            if found.count == titles.count { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .seconds(2))
        report("the welcome panel shows its two buttons (\(found.map(\.title)))", found.count == titles.count)
        for button in found {
            let hit = frameView.hitTest(center(of: button))
            let reachable = hit.map { $0 === button || $0.isDescendant(of: button) } ?? false
            report("a click on “\(button.title)” lands on the button: \(chain(of: hit))", reachable)
        }
        guard let choose = found.first(where: { $0.title == titles[0] }),
              let sample = found.first(where: { $0.title == titles[1] }) else { return }

        report("a click on Choose Music Folder… reaches its action", await clickAndWatch(choose))
        try? await Task.sleep(for: .seconds(1))
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        try? await Task.sleep(for: .seconds(1))
        report("a click on Download Sample Album reaches its action", await clickAndWatch(sample))
    }

    private static func exerciseZoom(window: NSWindow?) async {
        try? await Task.sleep(for: .seconds(6))
        let original = MacInterfaceScale.current
        MacInterfaceScale.set(MacInterfaceScale.standard)
        window?.setContentSize(NSSize(width: 1000, height: 640))
        try? await Task.sleep(for: .seconds(1))
        startHeroPlayback()
        try? await Task.sleep(for: .seconds(2))
        for _ in 0..<2 {
            NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
            try? await Task.sleep(for: .seconds(2))
            NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
            try? await Task.sleep(for: .seconds(1))
        }
        let steps = (0...10).map { MacInterfaceScale.standard + CGFloat($0) * MacInterfaceScale.step }
        for scale in steps + steps.reversed() {
            MacInterfaceScale.set(scale)
            try? await Task.sleep(for: .milliseconds(450))
        }
        MacInterfaceScale.set(original)
        AudioPlayer.shared.togglePlayPause()
        MidgarLog.info("DebugDrive: zoom exercise PASS — survived \(steps.count * 2) scale changes", category: .general)
    }

    private static func startHeroPlayback() {
        let hero = Library.shared.albums.first { $0.title == "Parallax Hours" } ?? Library.shared.albums.first
        guard let hero, !hero.tracks.isEmpty else {
            MidgarLog.error("DebugDrive: no album available for hero playback", category: .general)
            return
        }
        AudioPlayer.shared.volume = 0.02
        let index = hero.tracks.firstIndex { $0.title == "Slow Machine" } ?? 0
        AudioPlayer.shared.play(hero.tracks, startingAt: index)
        AudioPlayer.shared.seek(to: 58)
    }

    /// Playback from the middle of the longest album on hand, so the queue panel
    /// has real history above the current track — the case where merely
    /// scrolling the row into view leaves it off the bottom of the panel.
    private static func startDeepPlayback() {
        guard let album = Library.shared.albums.max(by: { $0.tracks.count < $1.tracks.count }),
              album.tracks.count > 4 else {
            startHeroPlayback()
            return
        }
        AudioPlayer.shared.volume = 0.02
        let last = CommandLine.arguments.contains("--deep-last")
        AudioPlayer.shared.play(album.tracks, startingAt: last ? album.tracks.count - 1 : album.tracks.count / 2)
        AudioPlayer.shared.seek(to: 45)
    }

    /// Captures the window's first sheet — the paywall, pair it with
    /// `--trial-day N` to render any day of the runway — through the same
    /// cached-display path the Stage B drive uses for sheets.
    static func captureSheet(of window: NSWindow?, name: String) {
        guard let sheet = window?.sheets.first else {
            MidgarLog.error("DebugDrive: no sheet to capture for \(name)", category: .general)
            return
        }
        sheet.contentView?.layoutSubtreeIfNeeded()
        sheet.displayIfNeeded()
        guard let data = windowServerPNG(sheet) ?? cachedDisplayPNG(sheet) else {
            MidgarLog.error("DebugDrive: sheet capture failed for \(name)", category: .general)
            return
        }
        let path = NSTemporaryDirectory() + name + ".png"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            MidgarLog.info("DebugDrive: captured sheet to \(path)", category: .general)
        } catch {
            MidgarLog.error("DebugDrive: sheet capture write failed: \(error.localizedDescription)", category: .general)
        }
    }

    /// Drives the equalizer deck's pointer callbacks through the screen's real
    /// timing and logs PASS/FAIL per expectation: a pointer that rests plays a
    /// preset, a sweep switches at once, leaving ends it after the grace, and a
    /// click keeps one as a single undo step.
    private static func exerciseDeck(_ screen: MacEqualizerViewController, engine: EqualizerEngine) async {
        func report(_ expectation: String, _ passed: Bool) {
            MidgarLog.info("DeckExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .general)
        }
        let treble = EqualizerPresets.id(forKey: "trebleBoost")
        let vocal = EqualizerPresets.id(forKey: "vocal")
        let bass = EqualizerPresets.id(forKey: "bassBoost")
        let inForce = engine.profileInForce.id
        screen.exercisePointer(at: treble)
        try? await Task.sleep(for: .milliseconds(30))
        report("a pointer that has not rested 90 ms plays nothing yet", screen.auditionedPresetID == nil)
        try? await Task.sleep(for: .milliseconds(200))
        report("after resting it plays the preset, the engine auditions it and the curve previews", screen.auditionedPresetID == treble && engine.auditioned?.id == treble && screen.curveIsPreviewing)
        report("auditioning leaves the saved profile alone", engine.profileInForce.id == inForce)
        screen.exercisePointer(at: vocal)
        report("while one plays the next switches at once", screen.auditionedPresetID == vocal && engine.auditioned?.id == vocal)
        screen.exercisePointer(at: nil)
        try? await Task.sleep(for: .milliseconds(60))
        report("the preview survives inside the 160 ms leave grace", screen.auditionedPresetID == vocal)
        screen.exercisePointer(at: bass)
        try? await Task.sleep(for: .milliseconds(250))
        report("entering another preset inside the grace cancels the end", screen.auditionedPresetID == bass)
        screen.exercisePointer(at: nil)
        try? await Task.sleep(for: .milliseconds(300))
        report("leaving the deck puts back what was playing", screen.auditionedPresetID == nil && engine.auditioned == nil && !screen.curveIsPreviewing && engine.profileInForce.id == inForce)
        screen.exercisePointer(at: bass)
        try? await Task.sleep(for: .milliseconds(200))
        screen.exerciseKeep(bass)
        report("clicking keeps the preset and ends the audition", engine.profileInForce.id == bass && engine.auditioned == nil && screen.auditionedPresetID == nil)
        controllerUndo(screen)?.undo()
        report("one undo puts back the previous profile", engine.profileInForce.id == inForce)
    }

    private static func controllerUndo(_ screen: MacEqualizerViewController) -> UndoManager? {
        screen.view.window?.undoManager
    }

    static func capture(window: NSWindow?, name: String) {
        if let window {
            MidgarLog.info(
                "DebugDrive: capture \(name) — frame \(window.frame), screen \(window.screen?.frame ?? .zero), backingScale \(window.backingScaleFactor)",
                category: .general
            )
        }
        if let root = window?.contentViewController as? RootContainerViewController {
            let sidebar = root.splitViewController.sidebarViewController
            MidgarLog.info("DebugDrive: sidebar renders \(sidebar.visibleRowCount) rows", category: .general)
        }
        if let contentView = window?.contentView,
           let tree = contentView.perform(NSSelectorFromString("_subtreeDescription"))?.takeUnretainedValue() as? String {
            let treePath = NSTemporaryDirectory() + "flaccy-viewtree.txt"
            try? tree.write(to: URL(fileURLWithPath: treePath), atomically: true, encoding: .utf8)
            MidgarLog.info("DebugDrive: view tree dumped to \(treePath)", category: .general)
        }
        guard let data = windowServerPNG(window) ?? cachedDisplayPNG(window) else {
            MidgarLog.error("DebugDrive: no capture path produced an image", category: .general)
            return
        }
        let path = NSTemporaryDirectory() + name + ".png"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            MidgarLog.info("DebugDrive: captured window to \(path)", category: .general)
        } catch {
            MidgarLog.error("DebugDrive: window capture failed: \(error.localizedDescription)", category: .general)
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
            MidgarLog.error("DebugDrive: WindowServer capture unavailable, falling back to cacheDisplay", category: .general)
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
            MidgarLog.error("DebugDrive: need 2+ albums to exercise library", category: .general)
            return
        }

        AudioPlayer.shared.play(first.tracks, startingAt: 0)
        try? await Task.sleep(for: .seconds(1))
        MidgarLog.info(
            "DebugDrive: grid play — now \(AudioPlayer.shared.currentTrack?.title ?? "none"), queue \(AudioPlayer.shared.queue.count)",
            category: .general
        )

        if let next = second.tracks.first {
            AudioPlayer.shared.insertNext(next)
            MidgarLog.info("DebugDrive: Play Next inserted \(next.title), queue \(AudioPlayer.shared.queue.count)", category: .general)
        }
        if let queued = second.tracks.last {
            AudioPlayer.shared.addToQueue(queued)
            MidgarLog.info("DebugDrive: Add to Queue appended \(queued.title), queue \(AudioPlayer.shared.queue.count)", category: .general)
        }

        do {
            let playlist = try DatabaseManager.shared.createPlaylist(name: "DebugDrive Mix")
            guard let playlistId = playlist.id else { return }
            PlaylistActions.add(Array(first.tracks.prefix(3)), toPlaylist: playlistId, named: playlist.name, in: window)
            var records = try DatabaseManager.shared.fetchPlaylistTracks(playlistId: playlistId)
            MidgarLog.info("DebugDrive: playlist has \(records.count) rows", category: .general)
            records.reverse()
            PlaylistActions.persistOrder(records)
            let reordered = try DatabaseManager.shared.fetchPlaylistTracks(playlistId: playlistId)
            MidgarLog.info(
                "DebugDrive: reorder check — first row now \(reordered.first?.trackFileURL ?? "none")",
                category: .general
            )
            if let victim = reordered.first?.id {
                try DatabaseManager.shared.removeTrackFromPlaylist(id: victim)
                let remaining = try DatabaseManager.shared.fetchPlaylistTracks(playlistId: playlistId)
                MidgarLog.info("DebugDrive: row removed, \(remaining.count) remain", category: .general)
            }
            try DatabaseManager.shared.deletePlaylist(id: playlistId)
            MidgarLog.info("DebugDrive: playlist deleted", category: .general)
        } catch {
            MidgarLog.error("DebugDrive: playlist exercise failed: \(error.localizedDescription)", category: .general)
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
                await Library.shared.importFiles(from: [stagedFile]) { _ in }
                let after = Library.shared.allTracks.count
                MidgarLog.info("DebugDrive: drop import — tracks \(before) → \(after)", category: .general)
                try? FileManager.default.removeItem(at: staging)
            } catch {
                MidgarLog.error("DebugDrive: import exercise failed: \(error.localizedDescription)", category: .general)
            }
        }
        MidgarLog.info("DebugDrive: library exercise complete", category: .general)
    }

    /// Imports a staged compilation folder twice through the real importer and
    /// checks the tree it leaves: the folder keeps its name and both discs,
    /// lyrics travel, artwork and hidden files do not, no `.part` survives, and
    /// the second run copies nothing. The folder is removed again afterwards.
    private static func exerciseFolderImport() async {
        var attempts = 0
        while Library.shared.allTracks.count < 2, attempts < 40 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        let tracks = Library.shared.allTracks.filter { $0.fileURL.pathExtension.lowercased() == "flac" }
        guard tracks.count >= 2 else {
            MidgarLog.error("DebugDrive: import exercise needs two FLAC tracks", category: .general)
            return
        }
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("DebugDriveFolder", isDirectory: true)
        let folderName = "Debug Drive Compilation"
        let folder = staging.appendingPathComponent(folderName, isDirectory: true)
        let imported = LibraryPaths.root.appendingPathComponent(folderName, isDirectory: true)
        do {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: imported)
            try fileManager.createDirectory(at: folder.appendingPathComponent("CD1"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: folder.appendingPathComponent("CD2"), withIntermediateDirectories: true)
            try fileManager.copyItem(at: tracks[0].fileURL, to: folder.appendingPathComponent("CD1/01.flac"))
            try fileManager.copyItem(at: tracks[1].fileURL, to: folder.appendingPathComponent("CD2/01.flac"))
            try Data("[00:01.00]debug".utf8).write(to: folder.appendingPathComponent("CD1/01.lrc"))
            try Data([0xFF, 0xD8]).write(to: folder.appendingPathComponent("cover.jpg"))
            try Data([0]).write(to: folder.appendingPathComponent(".hidden.flac"))
        } catch {
            MidgarLog.error("DebugDrive: import staging failed: \(error.localizedDescription)", category: .general)
            return
        }

        let first = await Library.shared.importFiles(from: [folder]) { progress in
            MidgarLog.info("DebugDrive: import progress \(progress)", category: .general)
        }
        let second = await Library.shared.importFiles(from: [folder]) { _ in }
        let expectations: [(String, Bool)] = [
            ("first run imported 2, skipped 0, failed 0", first == LibraryImportOutcome(imported: 2, skipped: 0, failed: 0)),
            ("second run imported 0, skipped 2, failed 0", second == LibraryImportOutcome(imported: 0, skipped: 2, failed: 0)),
            ("CD1/01.flac kept its disc", fileManager.fileExists(atPath: imported.appendingPathComponent("CD1/01.flac").path)),
            ("CD2/01.flac kept its disc", fileManager.fileExists(atPath: imported.appendingPathComponent("CD2/01.flac").path)),
            ("lyrics travelled", fileManager.fileExists(atPath: imported.appendingPathComponent("CD1/01.lrc").path)),
            ("artwork stayed behind", !fileManager.fileExists(atPath: imported.appendingPathComponent("cover.jpg").path)),
            ("hidden file stayed behind", !fileManager.fileExists(atPath: imported.appendingPathComponent(".hidden.flac").path)),
            ("no second copy", !fileManager.fileExists(atPath: imported.appendingPathComponent("CD1/01_1.flac").path)),
            ("no staging left", !fileManager.fileExists(atPath: imported.appendingPathComponent("CD1/.01.flac.flaccy-part").path)),
            ("library indexed both", Library.shared.allTracks.filter { $0.fileURL.path.contains(folderName) }.count == 2),
        ]
        for (name, passed) in expectations {
            MidgarLog.info("DebugDrive: import \(passed ? "PASS" : "FAIL") — \(name)", category: .general)
        }
        MidgarLog.info("DebugDrive: import outcomes \(first) then \(second)", category: .general)
        try? fileManager.removeItem(at: imported)
        try? fileManager.removeItem(at: staging)
        await Library.shared.reload()
        let verdict = expectations.allSatisfy(\.1) ? "PASSED" : "FAILED"
        MidgarLog.info("DebugDrive: import exercise \(verdict)", category: .general)
    }

    private static func exercise(window: NSWindow?) async {
        AudioPlayer.shared.volume = 0.05
        var attempts = 0
        while Library.shared.albums.isEmpty, attempts < 40 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        guard let album = Library.shared.albums.first, !album.tracks.isEmpty else {
            MidgarLog.error("DebugDrive: no albums to exercise", category: .general)
            return
        }
        MidgarLog.info("DebugDrive: playing \(album.title) — \(album.artist)", category: .general)
        AudioPlayer.shared.play(album.tracks, startingAt: 0)

        try? await Task.sleep(for: .seconds(2))
        MidgarLog.info("DebugDrive: seek to 20s (playing: \(AudioPlayer.shared.isPlaying))", category: .general)
        AudioPlayer.shared.seek(to: 20)

        try? await Task.sleep(for: .seconds(1))
        MidgarLog.info("DebugDrive: pause", category: .general)
        AudioPlayer.shared.togglePlayPause()

        try? await Task.sleep(for: .seconds(1))
        MidgarLog.info("DebugDrive: resume", category: .general)
        AudioPlayer.shared.togglePlayPause()

        try? await Task.sleep(for: .seconds(1))
        MidgarLog.info("DebugDrive: next track", category: .general)
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
        MidgarLog.info(
            "DebugDrive: exercise complete (playing: \(AudioPlayer.shared.isPlaying), track: \(AudioPlayer.shared.currentTrack?.title ?? "none"), time: \(AudioPlayer.shared.currentTime))",
            category: .general
        )
    }
}
#endif
