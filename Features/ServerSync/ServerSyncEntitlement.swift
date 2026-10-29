import Foundation

/// Whether Flaccy Server sync is allowed to run, readable from the engine's own queue.
///
/// `PurchaseManager` lives on the main actor and the engine asks from anywhere, so the lifecycle copies the answer here
/// whenever the purchase state changes. It starts true: a person whose purchase has not loaded yet is never shown the Pro
/// line, the same reason `PurchaseManager.allowsPlayback` waits for the entitlements.
nonisolated final class ServerSyncEntitlement: @unchecked Sendable {

    static let shared = ServerSyncEntitlement()

    private let lock = NSLock()
    private var granted = true

    var isEntitled: Bool {
        lock.withLock { granted }
    }

    /// Stores the answer and says whether it changed.
    @discardableResult
    func set(_ value: Bool) -> Bool {
        lock.withLock {
            defer { granted = value }
            return granted != value
        }
    }
}

extension PurchaseManager {

    /// Sync is part of Flaccy Pro: a purchase, or a trial that has not run out. A trial that has not started yet counts, and so
    /// does an expired state read before the entitlements loaded, exactly as playback does.
    var includesServerSync: Bool {
        allowsPlayback
    }
}
