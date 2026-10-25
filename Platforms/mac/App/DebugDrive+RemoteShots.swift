import MidgarCore
#if DEBUG
import AppKit
import FlaccyCore

extension DebugDrive {

    /// Opens the Mac screens for remote libraries for a picture: launch with `--shot-remote <screen>`
    /// and `FLACCY_EXERCISE_REMOTE`, where the screen is `servers`, `add-server`, `songs` or
    /// `nowplaying-light`. The pictures land in the app's temporary folder.
    static func runRemoteShotIfRequested(window: NSWindow?) {
        guard let screen = RemoteShotSeed.requestedScreen else { return }
        Task {
            guard let server = await RemoteShotSeed.prepare() else { return }
            switch screen {
            case "songs": await shotSongs(window: window, server: server)
            case "nowplaying-light": await shotNowPlayingLight(window: window)
            case "add-server": await shotServers(addServer: true)
            default: await shotServers(addServer: false)
            }
            RemoteShotSeed.ready(screen)
        }
    }

    private static func shotServers(addServer: Bool) async {
        (NSApp.delegate as? MacAppDelegate)?.showServersSettings()
        try? await Task.sleep(for: .seconds(3))
        let settingsWindow = NSApp.windows.first { $0.contentViewController is SettingsTabViewController }
        guard let tabs = settingsWindow?.contentViewController as? SettingsTabViewController,
              let pane = tabs.tabViewItems.compactMap({ $0.viewController as? ServersSettingsPane }).first
        else { return RemoteShotSeed.fail("the Servers pane did not open") }
        if addServer {
            pane.presentAddServer(link: nil)
            try? await Task.sleep(for: .seconds(2))
            if let sheet = settingsWindow?.attachedSheet,
               let panel = sheet.contentViewController as? AddServerPanelViewController,
               let credentials = RemoteShotSeed.credentials {
                await panel.fillForCapture(address: credentials.address, username: credentials.username, password: credentials.password)
                try? await Task.sleep(for: .seconds(2))
                captureSheet(of: settingsWindow, name: "flaccy-shot-remote-add-server")
                return
            }
        }
        capture(window: settingsWindow, name: "flaccy-shot-remote-servers")
    }

    private static func shotSongs(window: NSWindow?, server: RemoteServerRecord) async {
        _ = await ReexportExercise.seedRevisedSong()
        MidgarLog.info("REMOTE SHOT: the library holds \(Library.shared.allTracks.count) songs, \(Library.shared.allTracks.filter { $0.remoteSong != nil }.count) from the server", category: .content)
        NotificationCenter.default.post(
            name: .flaccyShowSection, object: nil,
            userInfo: [SectionNotificationKey.section: SidebarSection.songs.rawValue]
        )
        try? await Task.sleep(for: .seconds(3))
        if let songs: SongsTableViewController = findController(in: window?.contentViewController) {
            songs.selectSourceForCapture(.server(server.id))
        }
        try? await Task.sleep(for: .seconds(2))
        capture(window: window, name: "flaccy-shot-remote-songs")
    }

    private static func shotNowPlayingLight(window: NSWindow?) async {
        NSApp.appearance = NSAppearance(named: .aqua)
        let tracks = Library.shared.allTracks.filter { $0.remoteSong != nil && $0.codec == "FLAC" }
        guard let track = tracks.first else { return RemoteShotSeed.fail("no remote FLAC song to play") }
        AudioPlayer.shared.volume = 0.02
        AudioPlayer.shared.play([track], startingAt: 0)
        try? await Task.sleep(for: .seconds(2))
        NowPlayingLayout.lyricsShown = false
        NowPlayingLayout.queueShown = false
        NotificationCenter.default.post(name: .flaccyToggleNowPlaying, object: nil)
        try? await Task.sleep(for: .seconds(4))
        capture(window: window, name: "flaccy-shot-remote-nowplaying-light")
    }
}
#endif
