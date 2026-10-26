import Foundation

/// Everything a call to Flaccy Server can fail with, typed so the UI can pick the row of the failure table.
public enum ServerSyncError: Error, Hashable, Sendable {
    case noNetwork
    case offline(String)
    case timedOut
    case nameNotFound
    case unauthorized
    case enrollInvalid
    case rateLimited(retryAfterSeconds: Int?)
    case incarnationChanged(String)
    case cookieAhead(String?)
    case instanceConflict
    case mutationGap(have: Int64)
    case clockBehind
    case diskFull
    case serverFailure(status: Int)
    case notAFlaccyServer
    case serverTooOld
    case appTooOld
    case refused(status: Int, code: String)
    case malformed(String)
    case notConnected

    /// True for a failure worth retrying after a pause.
    public var isTransient: Bool {
        switch self {
        case .noNetwork, .offline, .timedOut, .serverFailure, .rateLimited: true
        default: false
        }
    }

    /// True when the server cannot be reached at all, as opposed to answering badly.
    public var isUnreachable: Bool {
        switch self {
        case .noNetwork, .offline, .timedOut, .nameNotFound: true
        default: false
        }
    }

    /// The row of the failure table of docs/server/UX.md section 3 this failure belongs to.
    public var kind: ServerSyncFailureKind {
        switch self {
        case .noNetwork, .offline, .timedOut: .unreachable
        case .nameNotFound: .nameNotFound
        case .enrollInvalid: .codeRefused
        case .rateLimited: .tooManyTries
        case .notAFlaccyServer: .notAFlaccyServer
        case .serverTooOld: .serverTooOld
        case .appTooOld: .appTooOld
        case .clockBehind: .serverClockWrong
        case .diskFull: .diskFull
        case .unauthorized: .deviceRemoved
        default: .other
        }
    }

    /// Maps an HTTP status and the error body to the typed failure.
    public static func from(status: Int, body: ServerErrorBody?, retryAfterSeconds: Int?) -> ServerSyncError {
        let code = body?.error.code ?? ""
        let incarnation = body?.error.incarnation ?? body?.incarnation
        let have = body?.error.have ?? body?.have ?? 0
        switch (status, code) {
        case (401, "enroll_invalid"): return .enrollInvalid
        case (401, _): return .unauthorized
        case (409, "incarnation_changed"): return .incarnationChanged(incarnation ?? "")
        case (409, "cookie_ahead"): return .cookieAhead(incarnation)
        case (409, "instance_conflict"): return .instanceConflict
        case (409, "mutation_gap"): return .mutationGap(have: have)
        case (503, "clock_behind"): return .clockBehind
        case (507, _), (413, "disk_full"), (503, "disk_full"): return .diskFull
        case (429, _): return .rateLimited(retryAfterSeconds: retryAfterSeconds)
        case (500...599, _): return .serverFailure(status: status)
        default: return .refused(status: status, code: code)
        }
    }
}

/// The rows of the failure table in docs/server/UX.md, by what the person does next.
public enum ServerSyncFailureKind: Hashable, Sendable {
    case unreachable
    case nameNotFound
    case codeRefused
    case tooManyTries
    case notAFlaccyServer
    case serverTooOld
    case appTooOld
    case serverClockWrong
    case diskFull
    case deviceRemoved
    case other
}

extension ServerSyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noNetwork: "This device has no network connection."
        case .offline(let cause): "Can't reach the server (\(cause))."
        case .timedOut: "The server did not answer in time."
        case .nameNotFound: "The server's name could not be found."
        case .unauthorized: "The server did not accept this device."
        case .enrollInvalid: "The enrollment code is wrong, used or expired."
        case .rateLimited: "The server asked Flaccy to slow down."
        case .incarnationChanged, .cookieAhead: "The server's data was replaced."
        case .instanceConflict: "The server met a different history for this device."
        case .mutationGap(let have): "The server is missing changes after \(have)."
        case .clockBehind: "The server's clock is behind."
        case .diskFull: "The server is out of disk space."
        case .serverFailure(let status): "The server failed with status \(status)."
        case .notAFlaccyServer: "The address did not answer as Flaccy Server."
        case .serverTooOld: "The server is older than this version of Flaccy supports."
        case .appTooOld: "The server needs a newer Flaccy."
        case .refused(let status, let code): "The server refused the request (\(status) \(code))."
        case .malformed(let cause): "The server sent something Flaccy cannot read (\(cause))."
        case .notConnected: "No Flaccy Server is connected."
        }
    }
}
