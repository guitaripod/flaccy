import FlaccyCore
import FlaccyEngine
import Foundation

/// The app's one sync engine over the library database, with the Keychain token store and the URLSession client.
///
/// Nothing starts it yet: the Servers screens call `connect`, `disconnect` and `devices` on it, read `statusUpdates()` for the status
/// line, and the app delegates call `launched()`, `foregrounded()`, `backgrounded()` and `resolveGhosts()` after a library scan.
/// Pro gating (`ServerSyncConfiguration.isEntitled`) and the network path monitor (`reachabilityChanged`) are wired where those
/// decisions are made.
nonisolated enum ServerSyncService {

    static let engine = ServerSyncEngine(
        database: DatabaseManager.shared,
        configuration: ServerSyncConfiguration(
            transports: FlaccyServerTransports(),
            tokens: RemoteCredentialStore.shared,
            platform: platform
        )
    )

    static var platform: String {
        #if os(macOS)
        "macos"
        #else
        "ios"
        #endif
    }
}
