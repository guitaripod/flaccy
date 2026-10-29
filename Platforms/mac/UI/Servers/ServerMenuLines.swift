import FlaccyServerEmbed
import Foundation

/// The status lines the menu bar extra shows for Flaccy Server: whether this Mac shares its library, and how its sync is doing.
enum ServerMenuLines {

    static func current() -> [String] {
        var lines: [String] = []
        if let sharing = SharingCopy.statusLine(for: MacLibrarySharing.shared.state) { lines.append(sharing) }
        if FlaccyServerStatusStore.shared.isConnected { lines.append(FlaccyServerStatusStore.shared.status.statusLine) }
        return lines
    }
}
