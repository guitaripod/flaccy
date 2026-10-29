import FlaccyCore
import FlaccyEngine
import Foundation

/// What the Servers list shows of a Flaccy Server: the one status line, how many songs it holds in the library, and how many
/// devices sync with it once that is known.
nonisolated struct FlaccyServerRowModel: Equatable, Hashable, Sendable {

    let statusLine: String
    let songs: String
    let deviceCount: Int?
    let needsPro: Bool

    init(status: SyncStatus, songCount: Int, deviceCount: Int?, now: Date = Date()) {
        statusLine = status.statusLine(now: now)
        songs = RemoteCopy.songs(songCount)
        self.deviceCount = deviceCount
        needsPro = status == .notPro
    }

    var syncBadge: String {
        String(localized: "Sync")
    }

    /// What VoiceOver reads after the server's name.
    var accessibilityValue: String {
        var parts = [syncBadge, statusLine, songs]
        if let deviceCount { parts.append(Self.devices(deviceCount)) }
        return parts.joined(separator: ", ")
    }

    static func devices(_ count: Int) -> String {
        count == 1 ? String(localized: "1 device") : String(localized: "\(count) devices")
    }
}
