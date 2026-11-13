import MidgarCore
#if DEBUG
import AppKit

extension DebugDrive {

    static let makePlaylistFlag = "--shot-make-playlist"

    /// The sentence after `--shot-make-playlist`, or nil when the flag stands alone or before another flag.
    static var makePlaylistRequest: String? {
        guard let request = value(after: makePlaylistFlag), !request.hasPrefix("--") else { return nil }
        return request
    }

    /// Opens Playlists and the Make a Playlist sheet over it. With a request it makes that playlist through the
    /// real flaccy-api and waits for the list; without one it shows the sheet as it opens. Captures the window
    /// and the sheet's own window.
    static func driveMakePlaylist(window: NSWindow?, request: String?) async {
        seedDemoPlaylists()
        NotificationCenter.default.post(
            name: .flaccyShowSection, object: nil,
            userInfo: [SectionNotificationKey.section: SidebarSection.playlists.rawValue]
        )
        try? await Task.sleep(for: .seconds(2))
        guard let host = window?.contentViewController else {
            MidgarLog.error("DebugDrive: make playlist found no window to present on", category: .general)
            return
        }
        let maker = MacPlaylistMakerViewController()
        host.presentAsSheet(maker)
        try? await Task.sleep(for: .seconds(1))
        if let request {
            maker.make(request)
            for _ in 0..<120 where !maker.hasSettled {
                try? await Task.sleep(for: .milliseconds(500))
            }
            MidgarLog.info("DebugDrive: make playlist settled \(maker.hasSettled)", category: .general)
            try? await Task.sleep(for: .seconds(1))
        }
        capture(window: window, name: "flaccy-shot-make-playlist")
        capture(window: maker.view.window, name: "flaccy-shot-make-playlist-sheet")
    }
}
#endif
