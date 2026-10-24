import Foundation

/// Runs `body` on the main actor and returns what it returns, from any thread.
///
/// MediaPlayer calls remote-command handlers on a queue of its own and needs the handler's status back before it
/// answers the system, so the handler cannot simply start a main-actor task. On the main thread the body runs at once;
/// from another thread the caller waits for the main queue to run it.
public func onMainActorSync<T: Sendable>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated(body)
    }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
}
