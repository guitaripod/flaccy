import Foundation

/// The calls the sync engine makes to one Flaccy Server. The app's URLSession client and the tests' fake server both implement it.
public protocol ServerSyncTransport: Sendable {
    func hello() async throws -> ServerHello
    func enroll(_ request: ServerEnrollRequest) async throws -> ServerEnrollReply
    func push(_ request: ServerPushRequest, incarnation: String?) async throws -> ServerPushResponse
    func pull(since: Int64, limit: Int, instance: String, incarnation: String?) async throws -> ServerPullResponse
    func listens(before: Int64?, after: Int64?, limit: Int, incarnation: String?) async throws -> ServerListensPage
    func devices() async throws -> [ServerDevice]
    func renameDevice(id: String, name: String) async throws
    func revokeDevice(id: String) async throws
    func putBlob(hash: String, data: Data, mime: String) async throws
    func blob(hash: String) async throws -> Data
}

/// Makes the transport for a server, signed in with `token` once the device has one.
public protocol ServerSyncTransportFactory: Sendable {
    func transport(baseURL: URL, token: String?) -> any ServerSyncTransport
}

/// Where a device token lives between launches. The Keychain is the only real home for it.
public protocol ServerTokenStore: Sendable {
    func token(serverID: String) -> String?
    func setToken(_ token: String, serverID: String) throws
    func removeToken(serverID: String)
}

/// Where the synced scalars that belong to other parts of the app go: equalizer profiles, settings and the like.
/// Lyrics offsets (`lyr/<songKey>`) never reach it. The engine calls it after the transaction that learned the value
/// has committed; `value` is nil when the scalar was cleared. Implementations must be idempotent.
public protocol ServerScalarSink: Sendable {
    func apply(key: String, value: ServerJSON?)
}
