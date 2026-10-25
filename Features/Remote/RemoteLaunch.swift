import Foundation

/// What the remote library does when the app starts: learns which songs are on the device and
/// which servers answer, trims the cache to its cap, then syncs the servers that have not been
/// read for six hours and sends the stars that never arrived.
@MainActor
enum RemoteLaunch {

    static func start() {
        Task {
            let cache = RemoteStreamCache.shared
            await Task.detached(priority: .utility) {
                RemoteAvailability.shared.load(cachesRoot: cache.cachesRoot, pinnedRoot: cache.pinnedRoot)
            }.value
            await RemoteServers.shared.refreshReachability()
            await cache.evictIfNeeded()
            await RemoteCatalogSync.shared.syncStaleServers()
        }
    }

    /// Asks every server again whether it answers, when the app comes back to the front.
    static func becameActive() {
        Task { await RemoteServers.shared.refreshReachability() }
    }
}
