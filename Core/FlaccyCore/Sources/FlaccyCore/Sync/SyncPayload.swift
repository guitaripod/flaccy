import Foundation

/// A WatchConnectivity message, application context or user-info dictionary on its way from the session's callback queue
/// to the queue that handles it. WatchConnectivity builds these as property lists of value types and is finished with
/// them before the callback returns, and nothing mutates one afterwards, so reading it from another queue is safe.
public struct SyncPayload: @unchecked Sendable {
    public let values: [String: Any]

    public init(_ values: [String: Any]) {
        self.values = values
    }
}
