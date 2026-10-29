import FlaccyCore
import FlaccyEngine
import Foundation
import MidgarCore

/// The music side of a Flaccy Server: one OpenSubsonic library, signed in with the device token the sync enrolled, so a single
/// row in Servers carries both the songs and the sync.
nonisolated enum FlaccyServerLibrary {

    static let serverType = "flaccy-server"

    /// Adds the server as a remote library, or refreshes the row it already has, and marks it as a Flaccy Server.
    @discardableResult
    static func register(_ connection: ServerSetupConnection) async throws -> RemoteServerRecord {
        guard let token = ServerSyncService.deviceToken(for: connection.baseURL) else { throw RemoteFailure.keychain }
        let record = try await RemoteServers.shared.add(
            address: connection.baseURL.absoluteString, name: connection.serverName,
            authentication: .apiKey(token), serverType: serverType
        )
        return record
    }

    /// A server on this device's own loopback address is the library the device itself shares, so its songs are already in the
    /// library and are never added a second time as a remote one.
    static func isThisDevicesOwn(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(url.host(percentEncoded: false)?.lowercased() ?? "")
    }

    /// The row of the Flaccy Server the person added, if any.
    static func record() -> RemoteServerRecord? {
        guard let server = ServerSyncService.engine.connectedServer else { return nil }
        return ((try? DatabaseManager.shared.fetchRemoteServers()) ?? []).first {
            $0.isFlaccyServer && $0.baseURL == server.url.absoluteString
        }
    }
}

extension RemoteServerRecord {

    nonisolated var isFlaccyServer: Bool {
        serverType == FlaccyServerLibrary.serverType
    }
}
