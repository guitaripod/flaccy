import FlaccyServerEmbed
import Foundation

/// The words of "Share this Mac's library": the status line for each state, and the explanations around the switch.
enum SharingCopy {

    static let tailscaleDownload = URL(string: "https://tailscale.com/download")

    static var title: String {
        String(localized: "Share this Mac's library")
    }

    static var explanation: String {
        String(localized: "Play this Mac's music on your iPhone and other devices, with playlists, loves and history in step. Devices on this Wi-Fi connect directly; Tailscale adds listening away from home.")
    }

    static var localNetwork: String {
        String(localized: "Devices on this Wi-Fi connect directly")
    }

    static var awayFromHome: String {
        String(localized: "Add Tailscale to listen away from home.")
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
        String(localized: "Tailscale is off and this Wi-Fi isn't shared, so only this Mac can play it. Turn on either one.")
    }

    static var noNetwork: String {
        String(localized: "This Mac isn't on a network, so only it can play the library. Join Wi-Fi or turn on Tailscale.")
    }

    /// Where devices connect, one line per way in: this Wi-Fi by name, and the tailnet when Tailscale is up.
    static func reach(_ sharing: LibrarySharing.Sharing) -> String {
        var lines: [String] = []
        if let host = sharing.localURL?.host(percentEncoded: false) {
            lines.append(String(localized: "On this Wi-Fi: \(host)"))
        }
        if let tailnet = sharing.addresses.tailnetHosts.first {
            lines.append(String(localized: "With Tailscale: \(tailnet)"))
        }
        return lines.joined(separator: "\n")
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
        guard sharing.reachesOtherDevices else { return sharing.sharesOnLocalNetwork ? noNetwork : tailscaleMissing }
        let line: String
        if let count = sharing.songCount, count > 0 {
            line = String(localized: "Sharing \(RemoteCopy.songs(count)) on \(sharing.name)")
        } else {
            line = String(localized: "Sharing on \(sharing.name)")
        }
        return sharing.reachesTailnet ? line : String(localized: "\(line). \(awayFromHome)")
    }

    static func devices(_ count: Int) -> String {
        count == 0 ? String(localized: "No devices have joined yet.") : FlaccyServerRowModel.devices(count)
    }

    static func countdown(_ seconds: Int) -> String {
        guard seconds > 0 else { return String(localized: "This code has expired. Make a new one.") }
        return String(localized: "This code works once and expires in \(String(format: "%d:%02d", seconds / 60, seconds % 60)).")
    }
}
