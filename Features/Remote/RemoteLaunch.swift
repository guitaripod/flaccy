import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What the remote library does when the app starts: learns which songs are on the device and
/// which servers answer, trims the cache to its cap, then syncs the servers that have not been
/// read for six hours and sends the stars that never arrived.
@MainActor
enum RemoteLaunch {

    static let changeProbeInterval: Duration = .seconds(120)

    private static var changeProbeLoop: Task<Void, Never>?

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
        startChangeProbeLoop()
    }

    /// Asks every server again whether it answers, and syncs those whose library changed, when the app comes back to the front.
    static func becameActive() {
        Task {
            await RemoteServers.shared.refreshReachability()
            await RemoteCatalogSync.shared.syncChangedServers()
        }
    }

    /// Asks the servers every `changeProbeInterval` whether their library changed while the app stays open, as the
    /// Linux client does, so a song added on a server appears without leaving and reopening the app.
    private static func startChangeProbeLoop() {
        guard changeProbeLoop == nil else { return }
        changeProbeLoop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: changeProbeInterval)
                guard isOnScreen else { continue }
                await RemoteCatalogSync.shared.syncChangedServers()
            }
        }
    }

    /// Whether the app is in front; an iPhone playing in the background does not spend its battery on the probe.
    private static var isOnScreen: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }
}
