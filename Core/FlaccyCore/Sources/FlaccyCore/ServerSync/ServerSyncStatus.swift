import Foundation

/// Where syncing with a Flaccy Server stands, for the status line of docs/server/UX.md section 4.
public enum SyncStatus: Hashable, Sendable {
    case notConnected
    case paused
    case upToDate(lastSyncedAt: Date?)
    case syncing(changes: Int)
    case offline(server: String, pending: Int)
    case unreachable(server: String)
    case notPro
    case appNeedsUpdate
    case serverNeedsUpdate
    case serverDiskFull(server: String)
    case serverClockWrong(server: String)
    case deviceRemoved(server: String)
    case listenOnly(server: String)
    case awaitingApproval(server: String)

    /// True while the person has something to do before syncing can continue.
    public var needsPerson: Bool {
        switch self {
        case .notPro, .appNeedsUpdate, .serverNeedsUpdate, .deviceRemoved, .listenOnly, .awaitingApproval: true
        default: false
        }
    }

    /// The status of an account that may not write to the server: only guests and pending devices have one.
    public static func readOnly(role: ServerRole, server: String) -> SyncStatus? {
        switch role {
        case .guest: .listenOnly(server: server)
        case .pending: .awaitingApproval(server: server)
        case .admin, .member: nil
        }
    }

    /// The status after a failed round: what the failure means for the status line.
    public static func after(failure: ServerSyncError, server: String, pending: Int) -> SyncStatus {
        if case .noNetwork = failure { return .offline(server: server, pending: pending) }
        switch failure.kind {
        case .appTooOld: return .appNeedsUpdate
        case .serverTooOld, .notAFlaccyServer: return .serverNeedsUpdate
        case .diskFull: return .serverDiskFull(server: server)
        case .serverClockWrong: return .serverClockWrong(server: server)
        case .deviceRemoved: return .deviceRemoved(server: server)
        case .unreachable, .nameNotFound, .tooManyTries, .codeRefused, .other: return .unreachable(server: server)
        }
    }
}
