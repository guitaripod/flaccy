import Foundation
import Network

/// Whether the 130 MB sample album may start on its own or needs a yes first.
/// A metered link (cellular, a hotspot) and Low Data Mode both ask; the
/// answer is a pure function of the two flags the system reports so the
/// decision is tested without a radio.
nonisolated enum SampleDownloadPolicy {

    enum Confirmation: Equatable {
        case cellular
        case lowDataMode
    }

    static let approximateMegabytes = 130

    static func confirmation(isExpensive: Bool, isConstrained: Bool) -> Confirmation? {
        if isConstrained { return .lowDataMode }
        if isExpensive { return .cellular }
        return nil
    }

    /// One look at the current route. `NWPathMonitor` has no synchronous
    /// read, so a monitor is started, asked once and cancelled.
    static func currentConfirmation() async -> Confirmation? {
        #if DEBUG
        if let forced = SampleDebugHooks.forcedConfirmation { return forced.value }
        #endif
        let path = await currentPath()
        return confirmation(isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    private static func currentPath() async -> NWPath {
        let monitor = NWPathMonitor()
        return await withCheckedContinuation { continuation in
            let gate = OnceGate()
            monitor.pathUpdateHandler = { path in
                guard gate.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.start(queue: DispatchQueue(label: "flaccy.sample-route"))
        }
    }

    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.withLock {
                defer { claimed = true }
                return !claimed
            }
        }
    }
}
