import FlaccyCore
import FlaccyEngine
import Foundation
import MidgarCore
import Network

/// Starts the sync engine and keeps it told about the app's moments: launch, foreground and background, the network path, the
/// purchase state, and the server's live channel. The app delegates call `launched()`, `becameActive()` and
/// `enteredBackground()`; the Add and detail screens call `connected()` and `disconnected()`.
@MainActor
final class ServerSyncLifecycle {

    static let shared = ServerSyncLifecycle()
    static let changesDidArrive = Notification.Name("ServerSyncChangesDidArrive")

    private let engine = ServerSyncService.engine
    private var pathMonitor: NWPathMonitor?
    private var liveChannel: FlaccyServerLiveChannel?
    private var observers: [NSObjectProtocol] = []
    private var isActive = false
    private var hasLaunched = false

    func launched() {
        guard !hasLaunched else { return }
        hasLaunched = true
        ServerSyncEntitlement.shared.set(PurchaseManager.shared.includesServerSync)
        FlaccyServerStatusStore.shared.start()
        observePurchases()
        startPathMonitor()
        Task { [engine] in
            await engine.setChangeHandler { changes in
                Task { @MainActor in ServerSyncLifecycle.shared.deliver(changes) }
            }
            await engine.launched()
        }
    }

    func becameActive() {
        isActive = true
        Task { await engine.foregrounded() }
        startLiveChannelIfWanted()
        addMusicIfMissing()
    }

    func enteredBackground() {
        isActive = false
        Task { await engine.backgrounded() }
        stopLiveChannel()
    }

    func connected() {
        Task { await engine.foregrounded() }
        startLiveChannelIfWanted()
    }

    func disconnected() {
        stopLiveChannel()
    }

    /// A server whose music could not be added when the person connected, for want of a network or a Keychain, is added the next time
    /// the app comes forward.
    private func addMusicIfMissing() {
        guard let server = ServerSyncService.engine.connectedServer, !FlaccyServerLibrary.isThisDevicesOwn(server.url),
              FlaccyServerLibrary.record() == nil
        else { return }
        Task {
            do {
                try await FlaccyServerLibrary.register(ServerSetupConnection(serverName: server.name, baseURL: server.url))
            } catch {
                MidgarLog.error("Adding the music of \(server.name) failed: \(error.localizedDescription)", category: .sync)
            }
        }
    }

    private func observePurchases() {
        let center = NotificationCenter.default
        for name in [PurchaseManager.stateDidChange, PurchaseManager.entitlementsDidLoad] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.entitlementMayHaveChanged() }
            })
        }
    }

    private func entitlementMayHaveChanged() {
        let granted = PurchaseManager.shared.includesServerSync
        guard ServerSyncEntitlement.shared.set(granted) else { return }
        MidgarLog.info("Sync entitlement changed: \(granted ? "on" : "off")", category: .sync)
        Task { await engine.syncNow() }
        if granted { startLiveChannelIfWanted() } else { stopLiveChannel() }
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [engine] path in
            let online = path.status == .satisfied
            Task { await engine.reachabilityChanged(isOnline: online) }
        }
        monitor.start(queue: DispatchQueue(label: "cc.midgarcorp.flaccy.server-path", qos: .utility))
        pathMonitor = monitor
    }

    private func startLiveChannelIfWanted() {
        guard isActive, liveChannel == nil, ServerSyncEntitlement.shared.isEntitled,
              let server = ServerSyncService.engine.connectedServer
        else { return }
        let channel = FlaccyServerLiveChannel(
            baseURL: server.url,
            token: { ServerSyncService.deviceToken(for: server.url) },
            onPoke: { Task { await ServerSyncService.engine.serverPoked() } }
        )
        liveChannel = channel
        Task { await channel.start() }
    }

    private func stopLiveChannel() {
        guard let channel = liveChannel else { return }
        liveChannel = nil
        Task { await channel.stop() }
    }

    private func deliver(_ changes: ServerSyncChanges) {
        MidgarLog.info(
            "A sync brought changes: playlists \(changes.playlists), loves \(changes.loves), plays \(changes.listens)",
            category: .sync
        )
        if changes.loves { LovedTracksService.shared.reloadFromDatabase() }
        if changes.listens > 0 { NotificationCenter.default.post(name: ListenHistorySync.didChange, object: nil) }
        if changes.playlists || changes.lyricsOffsets || changes.listens > 0 {
            NotificationCenter.default.post(name: Self.changesDidArrive, object: nil)
        }
    }
}
