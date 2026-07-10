import AppKit
import UniformTypeIdentifiers
import UserNotifications

@main
final class MacAppDelegate: NSObject, NSApplicationDelegate {

    private static let delegate = MacAppDelegate()

    private var mainWindowController: MainWindowController?
    private let folderWatcher = FolderWatcher()
    private var settingsWindowController: SettingsWindowController?
    private let menuBarExtra = MenuBarExtraController()
    private let trialAccessory = TrialStatusAccessoryController()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.info("Flaccy for Mac launched (root: \(LibraryRoot.current.path))", category: .general)
        #if DEBUG
        ScreenshotSeeder.seedIfRequested()
        #endif

        NSApp.mainMenu = MainMenu.build()
        PurchaseManager.shared.start()

        let windowController = MainWindowController()
        mainWindowController = windowController
        windowController.showWindow(nil)
        windowController.window?.addTitlebarAccessoryViewController(trialAccessory)
        NSApp.activate()

        menuBarExtra.onOpenApp = { [weak self] in
            self?.mainWindowController?.showWindow(nil)
        }
        menuBarExtra.bootstrap()

        UNUserNotificationCenter.current().delegate = self
        Task {
            await MacRecapNotificationScheduler.shared.refreshSchedule()
        }

        AudioPlayer.shared.restoreQueueState()
        Task {
            await AudioPlayer.shared.retryPendingScrobbles()
        }

        startLibraryPipeline()
        observeAppEvents()
        #if DEBUG
        DebugDrive.runIfRequested(window: windowController.window)
        runStageBDriveIfRequested()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioPlayer.shared.saveQueueState()
        folderWatcher.stop()
        AppLogger.info("Flaccy for Mac terminating", category: .general)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindowController?.showWindow(nil)
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let playPause = menu.addItem(
            withTitle: AudioPlayer.shared.isPlaying ? "Pause" : "Play",
            action: #selector(togglePlayPause(_:)), keyEquivalent: ""
        )
        playPause.target = self
        let next = menu.addItem(withTitle: "Next Track", action: #selector(nextTrack(_:)), keyEquivalent: "")
        next.target = self
        let previous = menu.addItem(withTitle: "Previous Track", action: #selector(previousTrack(_:)), keyEquivalent: "")
        previous.target = self
        if let track = AudioPlayer.shared.currentTrack {
            menu.addItem(.separator())
            let love = menu.addItem(withTitle: "Love \u{201C}\(track.title)\u{201D}", action: #selector(toggleLove(_:)), keyEquivalent: "")
            love.target = self
        }
        return menu
    }

    private func startLibraryPipeline() {
        folderWatcher.onChange = {
            Task { await Library.shared.reload() }
        }
        folderWatcher.start(watching: LibraryRoot.current)

        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryRootChanged), name: LibraryRoot.didChange, object: nil
        )
        Task { await Library.shared.reload() }
    }

    private func observeAppEvents() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(paywallRequired), name: PurchaseManager.paywallRequired, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshRecapSchedule), name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    @objc private func refreshRecapSchedule() {
        Task {
            await MacRecapNotificationScheduler.shared.refreshSchedule()
        }
    }

    @objc private func libraryRootChanged() {
        folderWatcher.start(watching: LibraryRoot.current)
        MacToast.show(
            "Library folder: \(LibraryRoot.current.lastPathComponent)",
            style: .success, in: mainWindowController?.window
        )
        Task { await Library.shared.reload() }
    }

    @objc private func paywallRequired() {
        presentPaywall()
    }

    private func presentPaywall() {
        guard let host = mainWindowController?.contentViewController else { return }
        mainWindowController?.showWindow(nil)
        NSApp.activate()
        if host.presentedViewControllers?.contains(where: { $0 is PaywallViewController }) == true {
            return
        }
        host.presentAsSheet(PaywallViewController())
    }

    @objc func chooseMusicFolder(_ sender: Any?) {
        guard let window = mainWindowController?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Flaccy indexes the folder in place — nothing is copied or moved."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try LibraryRoot.shared.chooseFolder(url)
            } catch {
                AppLogger.error("Bookmark creation failed: \(error.localizedDescription)", category: .content)
                MacToast.show("Couldn't access that folder.", style: .error, in: window)
            }
        }
    }

    @objc func importFiles(_ sender: Any?) {
        guard let window = mainWindowController?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.prompt = "Import"
        panel.message = "Copies files into Flaccy's library folder, preserving folder structure."
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let urls = panel.urls
            Task {
                await Library.shared.importFiles(from: urls)
                MacToast.show("Imported \(urls.count) item\(urls.count == 1 ? "" : "s")", style: .success, in: window)
            }
        }
    }

    @objc func revealLibraryFolder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([LibraryRoot.current])
    }

    @objc func showSettings(_ sender: Any?) {
        NotificationCenter.default.post(name: .flaccyShowSettings, object: nil)
        let controller = settingsWindowController ?? SettingsWindowController()
        settingsWindowController = controller
        controller.show()
    }

    @objc func focusSearch(_ sender: Any?) {
        NotificationCenter.default.post(name: .flaccyFocusSearch, object: nil)
    }

    @objc func togglePlayPause(_ sender: Any?) {
        AudioPlayer.shared.togglePlayPause()
    }

    @objc func nextTrack(_ sender: Any?) {
        AudioPlayer.shared.nextTrack()
    }

    @objc func previousTrack(_ sender: Any?) {
        AudioPlayer.shared.previousTrack()
    }

    @objc func toggleShuffle(_ sender: Any?) {
        AudioPlayer.shared.toggleShuffle()
    }

    @objc func cycleRepeatMode(_ sender: Any?) {
        AudioPlayer.shared.cycleRepeatMode()
    }

    @objc func toggleLove(_ sender: Any?) {
        guard let track = AudioPlayer.shared.currentTrack else { return }
        Task { _ = await LovedTracksService.shared.toggleLove(track: track) }
    }

    @objc func increaseVolume(_ sender: Any?) {
        AudioPlayer.shared.volume = min(1, AudioPlayer.shared.volume + 0.0625)
    }

    @objc func decreaseVolume(_ sender: Any?) {
        AudioPlayer.shared.volume = max(0, AudioPlayer.shared.volume - 0.0625)
    }

    @objc func showSection(_ sender: NSMenuItem) {
        NotificationCenter.default.post(
            name: .flaccyShowSection,
            object: nil,
            userInfo: [SectionNotificationKey.section: sender.tag]
        )
    }

    @objc func toggleQueue(_ sender: Any?) {
        NotificationCenter.default.post(name: .flaccyToggleQueue, object: nil)
    }

    @objc func toggleLyrics(_ sender: Any?) {
        NotificationCenter.default.post(name: .flaccyToggleLyrics, object: nil)
    }

    @objc func toggleNowPlaying(_ sender: Any?) {
        NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
    }
}

extension MacAppDelegate: UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard userInfo[MacRecapNotificationScheduler.destinationUserInfoKey] as? String
            == MacRecapNotificationScheduler.yearInMusicDestination else { return }
        mainWindowController?.showWindow(nil)
        NSApp.activate()
        NotificationCenter.default.post(
            name: .flaccyShowSection, object: nil,
            userInfo: [SectionNotificationKey.section: SidebarSection.yearInMusic.rawValue]
        )
        AppLogger.info("Recap notification opened Year in Music", category: .general)
    }
}

extension MacAppDelegate: NSMenuItemValidation {

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleLove(_:)):
            return AudioPlayer.shared.currentTrack != nil
        case #selector(togglePlayPause(_:)), #selector(nextTrack(_:)), #selector(previousTrack(_:)),
             #selector(toggleShuffle(_:)), #selector(cycleRepeatMode(_:)):
            return !AudioPlayer.shared.queue.isEmpty
        default:
            return true
        }
    }
}

#if DEBUG
/// Headless Stage B verification: `--b2-capture` walks every B2 surface with
/// seeded data and writes window PNGs plus Year in Music exports to /tmp;
/// `--b2-stress` opens and closes every surface three times so `leaks` can
/// prove nothing accumulates. DEBUG-only.
extension MacAppDelegate {

    private var stageBWindow: NSWindow? { mainWindowController?.window }

    func runStageBDriveIfRequested() {
        let capture = CommandLine.arguments.contains("--b2-capture")
        let stress = CommandLine.arguments.contains("--b2-stress")
        guard capture || stress else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.stageBWaitForLibrary()
            AudioPlayer.shared.volume = 0.02
            let hero = Library.shared.albums.first { $0.title == "Parallax Hours" } ?? Library.shared.albums.first
            if let hero, !hero.tracks.isEmpty {
                let heroIndex = hero.tracks.firstIndex { $0.title == "Slow Machine" } ?? 0
                AudioPlayer.shared.play(hero.tracks, startingAt: heroIndex)
                try? await Task.sleep(for: .seconds(1))
                AudioPlayer.shared.seek(to: 58)
            }
            try? await Task.sleep(for: .seconds(2))
            if stress {
                await self.stageBStress()
            }
            if capture {
                await self.stageBCapture()
            }
            AppLogger.info("StageBDrive: complete", category: .general)
        }
    }

    private func stageBWaitForLibrary() async {
        var attempts = 0
        while Library.shared.albums.isEmpty, attempts < 60 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
    }

    private func stageBCapture() async {
        let sections: [(SidebarSection, String)] = [
            (.charts, "charts"), (.yearInMusic, "yim"), (.wantlist, "wantlist"), (.listeningGuide, "guide"),
        ]
        for (section, name) in sections {
            NotificationCenter.default.post(
                name: .flaccyShowSection, object: nil,
                userInfo: [SectionNotificationKey.section: section.rawValue]
            )
            try? await Task.sleep(for: .seconds(name == "charts" ? 5 : 3))
            stageBCaptureWindow(stageBWindow, name: name)
        }

        NotificationCenter.default.post(name: .flaccyToggleQueue, object: nil)
        try? await Task.sleep(for: .seconds(2))
        stageBCaptureWindow(stageBWindow, name: "queue-inspector")
        let root = mainWindowController?.contentViewController as? RootContainerViewController
        stageBCaptureView(root?.splitViewController.inspectorContentView, name: "queue-inspector-panel")
        NotificationCenter.default.post(name: .flaccyToggleQueue, object: nil)

        AudioPlayer.shared.setSleepTimer(minutes: 15)
        try? await Task.sleep(for: .seconds(2))
        stageBCaptureWindow(stageBWindow, name: "transport-sleep")
        AppLogger.info("StageBDrive: sleep timer remaining after 2s = \(AudioPlayer.shared.sleepTimerRemaining ?? -1)", category: .playback)

        NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
        try? await Task.sleep(for: .seconds(3))
        stageBCaptureWindow(stageBWindow, name: "nowplaying")
        NotificationCenter.default.post(name: .flaccyToggleLyrics, object: nil)
        try? await Task.sleep(for: .seconds(3))
        stageBCaptureWindow(stageBWindow, name: "nowplaying-lyrics")
        NotificationCenter.default.post(name: .flaccyToggleQueue, object: nil)
        try? await Task.sleep(for: .seconds(2))
        stageBCaptureWindow(stageBWindow, name: "nowplaying-queue")
        NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
        try? await Task.sleep(for: .seconds(1))
        AudioPlayer.shared.cancelSleepTimer()

        showSettings(nil)
        try? await Task.sleep(for: .seconds(2))
        if let tabController = settingsTabController() {
            AppLogger.info("StageBDrive: settings window frame \(settingsWindow()?.frame ?? .zero), tab view subviews \(tabController.view.subviews.count)", category: .general)
            for (index, name) in ["settings-general", "settings-lastfm", "settings-recap", "settings-library", "settings-about"].enumerated() {
                tabController.selectedTabViewItemIndex = index
                try? await Task.sleep(for: .seconds(1))
                stageBCaptureView(tabController.tabViewItems[index].viewController?.view, name: name)
            }
        }
        settingsWindow()?.close()

        mainWindowController?.contentViewController?.presentAsSheet(PaywallViewController())
        try? await Task.sleep(for: .seconds(3))
        stageBCaptureWindow(stageBWindow?.sheets.first ?? stageBWindow, name: "paywall")
        dismissPresentedSheets()
        try? await Task.sleep(for: .seconds(1))

        stageBExportYearInMusic()
        await stageBVerifyScrobble()
    }

    private func stageBVerifyScrobble() async {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let before = (try? DatabaseManager.shared.scrobbleCountInRange(from: dayStart, to: .distantFuture)) ?? -1
        let duration = AudioPlayer.shared.duration
        AudioPlayer.shared.seek(to: max(0, duration - 30))
        try? await Task.sleep(for: .seconds(4))
        let after = (try? DatabaseManager.shared.scrobbleCountInRange(from: dayStart, to: .distantFuture)) ?? -1
        AppLogger.info("StageBDrive: scrobble eligibility check — rows today before=\(before) after=\(after) (duration \(duration))", category: .playback)
    }

    private func stageBStress() async {
        for round in 1...3 {
            AppLogger.info("StageBDrive: stress round \(round)", category: .general)
            for section in [SidebarSection.charts, .yearInMusic, .wantlist, .listeningGuide, .albums] {
                NotificationCenter.default.post(
                    name: .flaccyShowSection, object: nil,
                    userInfo: [SectionNotificationKey.section: section.rawValue]
                )
                try? await Task.sleep(for: .seconds(1))
            }
            NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
            try? await Task.sleep(for: .seconds(1))
            NotificationCenter.default.post(name: .flaccyToggleLyrics, object: nil)
            try? await Task.sleep(for: .milliseconds(700))
            NotificationCenter.default.post(name: .flaccyToggleQueue, object: nil)
            try? await Task.sleep(for: .milliseconds(700))
            NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
            try? await Task.sleep(for: .milliseconds(700))
            NotificationCenter.default.post(name: .flaccyToggleQueue, object: nil)
            try? await Task.sleep(for: .milliseconds(700))
            NotificationCenter.default.post(name: .flaccyToggleQueue, object: nil)
            try? await Task.sleep(for: .milliseconds(500))
            showSettings(nil)
            try? await Task.sleep(for: .milliseconds(800))
            settingsWindow()?.close()
            mainWindowController?.contentViewController?.presentAsSheet(PaywallViewController())
            try? await Task.sleep(for: .milliseconds(900))
            dismissPresentedSheets()
            try? await Task.sleep(for: .milliseconds(600))
        }
        AppLogger.info("StageBDrive: stress complete", category: .general)
    }

    private func settingsWindow() -> NSWindow? {
        settingsWindowController?.window
    }

    private func settingsTabController() -> SettingsTabViewController? {
        settingsWindowController?.contentViewController as? SettingsTabViewController
    }

    private func dismissPresentedSheets() {
        guard let host = mainWindowController?.contentViewController else { return }
        for presented in host.presentedViewControllers ?? [] {
            host.dismiss(presented)
        }
    }

    private func stageBCaptureView(_ view: NSView?, name: String) {
        guard let view else {
            AppLogger.error("StageBDrive: no view for \(name)", category: .general)
            return
        }
        view.layoutSubtreeIfNeeded()
        let scale = view.window?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        rep.size = view.bounds.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        view.displayIgnoringOpacity(view.bounds, in: context)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let path = NSTemporaryDirectory() + "flaccy-b2-\(name).png"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            AppLogger.info("StageBDrive: captured \(path) (\(view.bounds.size))", category: .general)
        } catch {
            AppLogger.error("StageBDrive: write failed for \(name): \(error.localizedDescription)", category: .general)
        }
    }

    private func stageBCaptureWindow(_ window: NSWindow?, name: String) {
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            AppLogger.error("StageBDrive: capture failed for \(name)", category: .general)
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let path = NSTemporaryDirectory() + "flaccy-b2-\(name).png"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            AppLogger.info("StageBDrive: captured \(path)", category: .general)
        } catch {
            AppLogger.error("StageBDrive: write failed for \(name): \(error.localizedDescription)", category: .general)
        }
    }

    private func stageBExportYearInMusic() {
        let year = Calendar.current.component(.year, from: Date())
        let data = YearInMusicService.shared.compute(year: year)
        guard data.hasContent else {
            AppLogger.error("StageBDrive: no YIM data to export", category: .general)
            return
        }
        let artwork = StoryArtwork.resolve(for: data)
        let seed = data.topArtists.first.map { "\($0.name)\(year)" } ?? "flaccy\(year)"
        let theme = StoryTheme.all(seedPalette: ArtworkPaletteExtractor.fallbackPalette(seed: seed))[0]
        for (format, suffix) in [(StoryFormat.story, "story"), (.post, "post")] {
            for slide in StorySlide.allCases {
                guard let image = StoryCardRenderer.makeImage(
                    slide: slide, data: data, artwork: artwork, theme: theme, format: format
                ), let png = image.pngData() else { continue }
                let path = NSTemporaryDirectory() + "flaccy-b2-yim-\(slide.displayName.lowercased().replacingOccurrences(of: " ", with: "-"))-\(suffix).png"
                try? png.write(to: URL(fileURLWithPath: path))
                AppLogger.info("StageBDrive: exported \(path)", category: .general)
            }
        }
        if let recap = ChartsViewModelSnapshotForDrive() {
            let palette = ArtworkPaletteExtractor.fallbackPalette(seed: "drive")
            if let card = RecapShareCardRenderer.makeImage(data: recap, palette: palette),
               let png = card.pngData() {
                let cardPath = NSTemporaryDirectory() + "flaccy-b2-recap-card.png"
                try? png.write(to: URL(fileURLWithPath: cardPath))
                AppLogger.info("StageBDrive: exported \(cardPath)", category: .general)
            }
        }
    }

    private func ChartsViewModelSnapshotForDrive() -> RecapData? {
        let stats = LastFMStatsService.shared
        return RecapData(
            userInfo: nil, period: .allTime,
            totalPlays: stats.totalPlays(), totalMinutes: stats.totalMinutes(),
            topArtists: stats.topArtists(period: .allTime, limit: 10),
            topAlbums: stats.topAlbums(period: .allTime, limit: 9),
            topTracks: stats.topTracks(period: .allTime, limit: 10),
            listeningClock: stats.listeningClock(), streak: stats.currentStreakDays(),
            heatmap: stats.dayHeatmap(), persona: stats.persona()
        )
    }
}
#endif
