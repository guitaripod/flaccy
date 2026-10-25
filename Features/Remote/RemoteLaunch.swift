import Foundation

/// What the remote library does when the app starts: trims the cache to its cap, then syncs the
/// servers that have not been read for six hours and sends the stars that never arrived.
@MainActor
enum RemoteLaunch {

    static func start() {
        Task {
            await RemoteStreamCache.shared.evictIfNeeded()
            await RemoteCatalogSync.shared.syncStaleServers()
        }
    }
}
