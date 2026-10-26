import Foundation

/// How long to wait between retries of a call that failed in a way that may pass.
public struct ServerSyncBackoff: Sendable, Equatable {
    public var baseSeconds: Double
    public var maxSeconds: Double
    public var attempts: Int

    public init(baseSeconds: Double, maxSeconds: Double, attempts: Int) {
        self.baseSeconds = baseSeconds
        self.maxSeconds = maxSeconds
        self.attempts = attempts
    }

    public static let standard = ServerSyncBackoff(baseSeconds: 0.5, maxSeconds: 8, attempts: 4)
    public static let none = ServerSyncBackoff(baseSeconds: 0, maxSeconds: 0, attempts: 1)

    /// The pause before retry number `attempt` (from 0): half the doubling ceiling plus up to the other half at random.
    /// `jitter` is a unit-interval random draw, a parameter so tests can pin it.
    public func pause(attempt: Int, jitter: Double) -> Double {
        let ceiling = min(baseSeconds * Double(1 << min(max(attempt, 0), 16)), maxSeconds)
        return ceiling / 2 + ceiling / 2 * min(max(jitter, 0), 1)
    }
}
