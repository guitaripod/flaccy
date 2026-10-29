import FlaccyCore
import FlaccyEngine
import Foundation

/// The app's one sync engine over the library database, with the Keychain token store and the URLSession client.
///
/// `ServerSyncLifecycle` starts it and feeds it the app's moments (launch, foreground, background, network path, purchases); the
/// Servers screens call `connect`, `disconnect` and `devices` on it and read `statusUpdates()` through `FlaccyServerStatusStore`.
nonisolated enum ServerSyncService {

    static let engine = ServerSyncEngine(
        database: DatabaseManager.shared,
        configuration: ServerSyncConfiguration(
            transports: FlaccyServerTransports(),
            tokens: RemoteCredentialStore.shared,
            platform: platform,
            isEntitled: { ServerSyncEntitlement.shared.isEntitled }
        )
    )

    static var platform: String {
        #if os(macOS)
        "macos"
        #else
        "ios"
        #endif
    }

    /// What this device is called in the server's list of devices.
    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        "iPhone"
        #endif
    }

    static func deviceToken(for baseURL: URL) -> String? {
        RemoteCredentialStore.shared.token(serverID: ServerSyncEngine.serverID(for: baseURL))
    }
}
