import Foundation

/// The rows of the failure table of docs/server/UX.md section 3, with the server name each one is about.
public enum ServerSetupFailure: Hashable, Sendable {
    case unreachable(server: String)
    case nameNotFound(server: String)
    case codeRefused(server: String)
    case tooManyTries
    case notAFlaccyServer(server: String)
    case serverTooOld
    case appTooOld(server: String)
    case serverClockWrong(server: String)
    case other(server: String)

    /// The row a thrown error belongs to. Anything the table does not name becomes `other`.
    public init(error: any Error, server: String) {
        guard let failure = error as? ServerSyncError else {
            self = .other(server: server)
            return
        }
        switch failure.kind {
        case .unreachable: self = .unreachable(server: server)
        case .nameNotFound: self = .nameNotFound(server: server)
        case .codeRefused: self = .codeRefused(server: server)
        case .tooManyTries: self = .tooManyTries
        case .notAFlaccyServer: self = .notAFlaccyServer(server: server)
        case .serverTooOld: self = .serverTooOld
        case .appTooOld: self = .appTooOld(server: server)
        case .serverClockWrong: self = .serverClockWrong(server: server)
        case .diskFull, .deviceRemoved, .other:
            self = .other(server: server)
        }
    }
}
