import Foundation

/// The calls the sync engine makes to one Flaccy Server. The app's URLSession client and the tests' fake server both implement it.
public protocol ServerSyncTransport: Sendable {
    var seenPin: String? { get }
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

/// How a client trusts the TLS key of a server: by the system's certificate authorities, by the pin a link or an earlier
/// connection gave, or, for an address typed by hand, whatever key it shows first, which is then pinned.
public enum ServerKeyTrust: Sendable, Equatable {
    case system
    case pinned(String)
    case firstContact

    /// The trust for `url`: its pin when there is one, the first key it shows for an `https` address on the local network,
    /// and the system's authorities otherwise (plain `http` on the tailnet, or a server with a real certificate).
    public static func forAddress(_ url: URL, pin: String?) -> ServerKeyTrust {
        guard url.scheme?.lowercased() == "https" else { return .system }
        if let pin, !pin.isEmpty { return .pinned(pin) }
        return LocalNetwork.isLocalHost(url.host(percentEncoded: false) ?? "") ? .firstContact : .system
    }
}

/// Makes the transport for a server, signed in with `token` once the device has one.
public protocol ServerSyncTransportFactory: Sendable {
    func transport(baseURL: URL, token: String?) -> any ServerSyncTransport
    func transport(baseURL: URL, token: String?, trust: ServerKeyTrust) -> any ServerSyncTransport
}

extension ServerSyncTransportFactory {
    public func transport(baseURL: URL, token: String?, trust: ServerKeyTrust) -> any ServerSyncTransport {
        transport(baseURL: baseURL, token: token)
    }
}

extension ServerSyncTransport {
    /// The pin of the key the server showed, for a transport that trusts on first contact; nil otherwise.
    public var seenPin: String? { nil }
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
