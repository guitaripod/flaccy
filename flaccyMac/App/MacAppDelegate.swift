import AppKit
import UniformTypeIdentifiers

@main
final class MacAppDelegate: NSObject, NSApplicationDelegate {

    private static let delegate = MacAppDelegate()

    private var mainWindowController: MainWindowController?
    private let folderWatcher = FolderWatcher()

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
        NSApp.activate()

        AudioPlayer.shared.restoreQueueState()
        Task {
            await AudioPlayer.shared.retryPendingScrobbles()
        }

        startLibraryPipeline()
        observeAppEvents()
        #if DEBUG
        DebugDrive.runIfRequested(window: windowController.window)
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
        MacToast.show(
            "Your trial has ended — unlock Flaccy Lifetime in Settings.",
            style: .info, in: mainWindowController?.window
        )
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
        MacToast.show("Settings arrive in a later stage.", style: .info, in: mainWindowController?.window)
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
