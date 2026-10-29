import FlaccyCore
import FlaccyEngine
import Foundation

/// The words the screens for remote libraries share on iPhone and Mac, so a server reads the
/// same everywhere: how many songs it holds, when it last synced, what a download is doing.
nonisolated enum RemoteCopy {

    static var explainer: String {
        String(localized: "Play a library from your own music server, such as Navidrome or Flaccy Server. Its songs join your library next to the ones on this device.")
    }

    static func songs(_ count: Int) -> String {
        count == 1 ? String(localized: "1 song") : String(localized: "\(LibraryLoadPhaseCopy.number(count)) songs")
    }

    /// "Synced 5 min ago", "Syncing…", the reason the last sync failed, or "Not synced yet".
    static func syncLine(for server: RemoteServerRow, now: Date = Date()) -> String {
        if server.isSyncing { return String(localized: "Syncing\u{2026}") }
        if let failure = server.lastFailure { return failure }
        guard let synced = server.lastSyncedAt else { return String(localized: "Not synced yet") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: synced, relativeTo: now)
        return String(localized: "Synced \(relative)")
    }

    static func detail(for server: RemoteServerRow, now: Date = Date()) -> String {
        [server.address, songs(server.songCount), syncLine(for: server, now: now)].joined(separator: " \u{00B7} ")
    }

    static func removalMessage(songCount: Int) -> String {
        String(localized: "This removes \(songs(songCount)) from your library and any playlists, and deletes the copies cached or downloaded on this device. The server itself is not changed.")
    }

    static func removed(name: String, songCount: Int) -> String {
        String(localized: "Removed \u{201C}\(name)\u{201D} and \(songs(songCount)) from your library.")
    }

    static func cacheUsage(cached: Int64, downloaded: Int64) -> String {
        let cachedText = byteText(cached)
        let downloadedText = byteText(downloaded)
        return String(localized: "In use: \(cachedText) cached, \(downloadedText) downloaded")
    }

    static func cacheLimit(gigabytes: Int) -> String {
        String(localized: "\(gigabytes) GB")
    }

    static func cacheCleared(bytes: Int64) -> String {
        String(localized: "Cleared \(byteText(bytes)) of cached songs. Downloads were not touched.")
    }

    static var cacheFooter: String {
        String(localized: "Songs you stream are kept here so they replay without the server. The least recently played go first once the limit is reached. Songs you download stay outside the limit.")
    }

    static func syncHeadline(for progress: RemoteSyncProgress) -> String {
        progress.isFirstSync
            ? String(localized: "Adding \(progress.serverName)")
            : String(localized: "Syncing \(progress.serverName)")
    }

    static func syncDetail(for progress: RemoteSyncProgress) -> String {
        let read = LibraryLoadPhaseCopy.number(progress.songsRead)
        guard let total = progress.songTotal, total >= progress.songsRead else { return songs(progress.songsRead) }
        return String(localized: "\(read) of \(LibraryLoadPhaseCopy.number(total)) songs")
    }

    static func syncAccessibilityValue(for progress: RemoteSyncProgress) -> String {
        let headline = syncHeadline(for: progress)
        let detail = syncDetail(for: progress)
        return String(localized: "\(headline), \(detail)")
    }

    static func downloading(_ count: Int) -> String {
        String(localized: "Downloading \(songs(count))")
    }

    static func downloading(done: Int, of total: Int) -> String {
        String(localized: "Downloading \(LibraryLoadPhaseCopy.number(done)) of \(songs(total))")
    }

    static func downloaded(_ count: Int) -> String {
        String(localized: "Downloaded \(songs(count)).")
    }

    static func downloadFailed(done: Int, total: Int, reason: String) -> String {
        if total == 1 { return reason }
        return String(localized: "Downloaded \(LibraryLoadPhaseCopy.number(done)) of \(songs(total)). \(reason)")
    }

    static func downloadsRemoved(_ count: Int) -> String {
        String(localized: "Removed \(songs(count)) from your downloads.")
    }

    static func downloadedAccessibility(_ label: String) -> String {
        String(localized: "\(label), Downloaded")
    }

    static var downloadedMarkLabel: String {
        String(localized: "Downloaded")
    }

    static func unavailable(title: String, server: String) -> String {
        String(localized: "\u{201C}\(title)\u{201D} isn\u{2019}t downloaded and \(server) can\u{2019}t be reached. Connect to the internet or Tailscale and try again.")
    }

    static var downloadAction: String { String(localized: "Download") }
    static var removeDownloadAction: String { String(localized: "Remove Download") }

    private static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}

/// What a Servers list needs of one server: its row and the live facts around it.
nonisolated struct RemoteServerRow: Sendable, Equatable, Hashable {
    let id: String
    let name: String
    let address: String
    let songCount: Int
    let lastSyncedAt: Date?
    let lastFailure: String?
    let isSyncing: Bool
    let flaccy: FlaccyServerRowModel?

    init(record: RemoteServerRecord, songCount: Int, flaccy: FlaccyServerRowModel? = nil) {
        self.flaccy = flaccy
        id = record.id
        name = record.name
        address = Self.displayAddress(record.baseURL)
        self.songCount = songCount
        lastSyncedAt = record.lastSyncedAt
        lastFailure = RemoteSyncStatus.shared.lastFailure(serverID: record.id)
        isSyncing = RemoteSyncStatus.shared.isSyncing(serverID: record.id)
    }

    private static func displayAddress(_ baseURL: String) -> String {
        guard let url = URL(string: baseURL), let host = url.host(percentEncoded: false) else { return baseURL }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}
