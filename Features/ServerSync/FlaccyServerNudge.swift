import Foundation

/// The quiet invitation to Flaccy Server: the footer of Settings > Servers for a person with no server, and the card of the
/// getting-started guide. Closing either hides both for good.
nonisolated enum FlaccyServerNudge {

    private static let key = "flaccy.server.nudgeDismissed"

    static var text: String {
        String(localized: "Have a computer with your music on it? Flaccy Server shares it with your other devices, and keeps playlists, loves and history in sync. It's free: flaccy.app/server.")
    }

    static var isDismissed: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func isVisible(serverCount: Int) -> Bool {
        serverCount == 0 && !isDismissed
    }

    static func dismiss() {
        UserDefaults.standard.set(true, forKey: key)
    }
}
