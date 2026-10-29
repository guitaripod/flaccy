import FlaccyCore
import FlaccyEngine
import Foundation

/// The app's side of `ServerSetupGateway`: the probe goes out on a throwaway client with the five second timeout, and
/// enrollment is the engine's own `connect`, which also starts the first sync.
nonisolated struct FlaccyServerSetupGateway: ServerSetupGateway {

    func hello(baseURL: URL) async throws -> ServerHello {
        try await FlaccyServerClient(baseURL: baseURL, token: nil).hello()
    }

    func connect(link: FlaccyServerLink, deviceName: String) async throws -> ServerSetupConnection {
        let connection = try await ServerSyncService.engine.connect(link: link, deviceName: deviceName)
        return ServerSetupConnection(serverName: connection.serverName, baseURL: link.baseURL)
    }
}
