import FlaccyCore
import FlaccyEngine
import Foundation

/// The sync engine's status, kept where the screens can read it without awaiting an actor, and announced when it changes.
@MainActor
final class FlaccyServerStatusStore {

    static let shared = FlaccyServerStatusStore()
    static let didChange = Notification.Name("FlaccyServerStatusDidChange")

    private(set) var status: SyncStatus = .notConnected
    private(set) var lastSyncedAt: Date?
    private(set) var deviceCount: Int?
    private var task: Task<Void, Never>?

    var isConnected: Bool {
        ServerSyncService.engine.connectedServer != nil && status != .notConnected
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            for await status in await ServerSyncService.engine.statusUpdates() {
                self?.apply(status)
            }
        }
    }

    func noteDevices(count: Int) {
        guard deviceCount != count else { return }
        deviceCount = count
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func forgetServer() {
        deviceCount = nil
        lastSyncedAt = nil
    }

    private func apply(_ status: SyncStatus) {
        if case .upToDate(let date?) = status { lastSyncedAt = date }
        guard status != self.status else { return }
        self.status = status
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
