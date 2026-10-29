import FlaccyServerEmbed
import Foundation

/// The words of "Share this Mac's library": the status line for each state, and the explanations around the switch.
enum SharingCopy {

    static let tailscaleDownload = URL(string: "https://tailscale.com/download")

    static var title: String {
        String(localized: "Share this Mac's library")
    }

    static var explanation: String {
        String(localized: "Share this Mac's library with your iPhone and other devices. Flaccy reaches them through Tailscale; nothing leaves your network.")
    }

    static var introTitle: String {
        String(localized: "Share this Mac's library?")
    }

    static var share: String {
        String(localized: "Share")
    }

    static var notNow: String {
        String(localized: "Not Now")
    }

    static var addDevice: String {
        String(localized: "Add a Device\u{2026}")
    }

    static var getTailscale: String {
        String(localized: "Get Tailscale")
    }

    static var openTailscale: String {
        String(localized: "Open Tailscale")
    }

    static var firewallHint: String {
        String(localized: "If macOS asks whether Flaccy may accept incoming connections, choose Allow.")
    }

    static var tailscaleMissing: String {
        String(localized: "Tailscale is not installed or not signed in: sharing on this Mac only")
    }

    static func statusLine(for state: LibrarySharing.State) -> String? {
        switch state {
        case .off:
            nil
        case .starting:
            String(localized: "Starting\u{2026}")
        case .sharing(let sharing):
            sharingLine(sharing)
        case .failed(.folderOffline):
            String(localized: "Can't reach the music folder. Reconnect its drive or choose a folder in Library settings, then turn sharing off and on.")
        case .failed(.server(let message)):
            String(localized: "Sharing didn't start. \(message)")
        }
    }

    private static func sharingLine(_ sharing: LibrarySharing.Sharing) -> String {
        guard sharing.reachesTailnet else { return tailscaleMissing }
        guard let count = sharing.songCount, count > 0 else { return String(localized: "Sharing on \(sharing.name)") }
        return String(localized: "Sharing \(RemoteCopy.songs(count)) on \(sharing.name)")
    }

    static func devices(_ count: Int) -> String {
        count == 0 ? String(localized: "No devices have joined yet.") : FlaccyServerRowModel.devices(count)
    }

    static func countdown(_ seconds: Int) -> String {
        guard seconds > 0 else { return String(localized: "This code has expired. Make a new one.") }
        return String(localized: "This code works once and expires in \(String(format: "%d:%02d", seconds / 60, seconds % 60)).")
    }
}
