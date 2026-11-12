import Foundation

/// The words of the welcome and of its Flaccy Server step.
nonisolated enum WelcomeCopy {

    static var title: String { String(localized: "Welcome to Flaccy") }
    static var subtitle: String { String(localized: "The player for the music you own.") }
    static var question: String { String(localized: "Where is your music?") }

    static var computerTitle: String { String(localized: "On my computer") }
    static var computerDetail: String {
        String(localized: "Send it over Wi-Fi from the computer's web browser, or stream all of it with Flaccy Server. Both free.")
    }
    static var filesTitle: String { (DeviceKind.isPad ? String(localized: "On this iPad or in Files") : String(localized: "On this iPhone or in Files")) }
    static var filesDetail: String { String(localized: "Add songs and folders from Files, iCloud Drive or a USB drive.") }
    static var serverTitle: String { String(localized: "On a music server") }
    static var serverDetail: String { String(localized: "Connect Navidrome, Jellyfin or another Subsonic server.") }

    static var sample: String { String(localized: "Just looking? Play the free sample album") }
    static var notNow: String { String(localized: "Not Now") }

    static var guideTitle: String { String(localized: "Connect Your Computer") }
    static var guideLead: String {
        (DeviceKind.isPad ? String(localized: "Flaccy Server plays the music on your Mac or PC on this iPad over your Wi-Fi, with playlists, loves and history in step. It's free, and your music never leaves your own network.") : String(localized: "Flaccy Server plays the music on your Mac or PC on this iPhone over your Wi-Fi, with playlists, loves and history in step. It's free, and your music never leaves your own network."))
    }
    static var awayTitle: String { String(localized: "Away from home?") }
    static var awayDetail: String {
        (DeviceKind.isPad ? String(localized: "Install Tailscale on this iPad and on your computer, signed in to the same account, and your music plays anywhere.") : String(localized: "Install Tailscale on this iPhone and on your computer, signed in to the same account, and your music plays anywhere."))
    }
    static var getTailscale: String { String(localized: "Get Tailscale") }
    static var stepServerTitle: String { String(localized: "Start Flaccy Server") }
    static var stepServerDetail: String {
        String(localized: "On a Mac, open Flaccy and turn on Settings › Servers › Share this Mac's library. On Linux or a NAS, install Flaccy Server and run flaccy-server setup.")
    }
    static var sendGuide: String { String(localized: "Send the Setup Guide to My Computer") }
    static var sendGuideMessage: String { String(localized: "Set up Flaccy Server on this computer") }
    static var stepScanTitle: String { String(localized: "Scan the code") }
    static var stepScanDetail: String {
        (DeviceKind.isPad ? String(localized: "Keep this iPad on the same Wi-Fi. When your computer shows a code, scan it and Flaccy connects.") : String(localized: "Keep this iPhone on the same Wi-Fi. When your computer shows a code, scan it and Flaccy connects."))
    }
    static var scan: String { String(localized: "Scan the Code") }
    static var typeInstead: String { String(localized: "Type the Address Instead") }
    static var proNote: String {
        String(localized: "Playing music from your server is free. Syncing playlists, loves and history across devices is part of Flaccy Pro.")
    }

    /// The public setup guide, the one link a person can open on the computer itself.
    static let setupGuideURL = URL(string: "https://midgarcorp.cc/flaccy/server")!
}
