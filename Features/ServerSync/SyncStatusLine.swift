import FlaccyCore
import Foundation

/// The one status line a Flaccy Server shows in Settings, as docs/server/UX.md section 4 words it.
extension SyncStatus {

    nonisolated var statusLine: String {
        statusLine(now: Date())
    }

    nonisolated func statusLine(now: Date) -> String {
        switch self {
        case .notConnected:
            String(localized: "No Flaccy Server is connected.")
        case .paused:
            String(localized: "Sync is off.")
        case .upToDate(let lastSyncedAt):
            Self.syncedLine(lastSyncedAt, now: now)
        case .syncing(let changes):
            changes > 0 ? String(localized: "Syncing \(changes) changes…") : String(localized: "Syncing…")
        case .offline(let server, let pending):
            pending > 0
                ? String(localized: "Offline. \(pending) changes will send when \(server) is reachable.")
                : String(localized: "Offline.")
        case .unreachable(let server):
            String(localized: "Can't reach \(server). Is Tailscale on?")
        case .notPro:
            String(localized: "Sync is a Flaccy Pro feature. Songs still stream.")
        case .appNeedsUpdate:
            String(localized: "Update Flaccy to keep syncing.")
        case .serverNeedsUpdate:
            String(localized: "Update your Flaccy Server to keep syncing.")
        case .serverDiskFull(let server):
            String(localized: "\(server) is out of disk space. Free some up and Flaccy retries by itself.")
        case .serverClockWrong(let server):
            String(localized: "The clock on \(server) is wrong. Sync is paused.")
        case .deviceRemoved(let server):
            String(localized: "This device was removed from \(server). Add the server again to keep syncing.")
        case .listenOnly(let server):
            String(localized: "This account can only listen. Ask the owner of \(server) to give it access.")
        case .awaitingApproval(let server):
            String(localized: "Waiting for approval. Ask the owner of \(server) to approve this device.")
        }
    }

    private nonisolated static func syncedLine(_ date: Date?, now: Date) -> String {
        guard let date, now.timeIntervalSince(date) >= 60 else { return String(localized: "Synced just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: date, relativeTo: now)
        return String(localized: "Synced \(relative)")
    }
}
