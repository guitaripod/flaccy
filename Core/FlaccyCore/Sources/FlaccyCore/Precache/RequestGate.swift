import Foundation

/// Spaces the requests of one server, whoever sends them, and honours the
/// cooldown it asked for. lrclib bans clients that ignore `Retry-After`, and it
/// bans by address, so the lyrics view and the background lane share one gate.
/// The clock is a parameter so the rules are testable. Mirrored in Rust as
/// `Gate` in `linux/src/precache/governor.rs`.
public struct RequestGate: Sendable {

    public enum Claim: Sendable, Equatable {
        /// Send after waiting this long.
        case after(TimeInterval)
        /// Do not send: the server asked for quiet for this much longer.
        case cooling(TimeInterval)
    }

    /// How much longer than asked a cooldown lasts, at most, so clients that
    /// were throttled together do not return together.
    public static let cooldownJitter = 0.3

    public let gap: TimeInterval
    private var nextSlot: Date?
    private var cooldownUntil: Date?

    public init(gap: TimeInterval) {
        self.gap = gap
    }

    /// Claims the next request slot and says how long to wait for it, or that
    /// the cooldown still left is longer than `patience` and nothing should be
    /// sent.
    public mutating func claim(now: Date, patience: TimeInterval) -> Claim {
        let cooling = cooldownLeft(now: now)
        if cooling > patience { return .cooling(cooling) }
        let slot = max(max(nextSlot ?? now, now), now.addingTimeInterval(cooling))
        nextSlot = slot.addingTimeInterval(gap)
        return .after(max(slot.timeIntervalSince(now), 0))
    }

    /// The server said to slow down: nothing is sent for `retryAfter`, plus up
    /// to 30 % so a crowd of clients spreads out.
    public mutating func throttled(now: Date, retryAfter: TimeInterval, jitter: Double) {
        let until = now.addingTimeInterval(retryAfter * (1 + Self.cooldownJitter * min(max(jitter, 0), 1)))
        if cooldownUntil.map({ $0 < until }) ?? true {
            cooldownUntil = until
        }
    }

    public func cooldownLeft(now: Date) -> TimeInterval {
        max(cooldownUntil.map { $0.timeIntervalSince(now) } ?? 0, 0)
    }
}

/// Rests a lane after consecutive failures, for longer each time. Mirrored in
/// Rust as `Breaker` in `linux/src/precache/governor.rs`.
public struct LaneBreaker: Sendable {

    /// Failures in a row before the lane rests.
    public static let tripAfter = 3

    /// A server that answers "busy" is alive and merely slow on the questions
    /// it was asked, so it takes a longer run of them, with no song done in
    /// between, before the whole lane rests: a few songs lrclib has to think
    /// about must not hold up the ones behind them.
    public static let busyTripAfter = 8

    private var consecutive = 0
    private var restingUntil: Date?
    public private(set) var last: PrecacheFailure?

    public init() {}

    public mutating func succeeded() {
        consecutive = 0
        restingUntil = nil
        last = nil
    }

    /// Counts a failure. A refusal (`throttled`, `blocked`) rests the lane at
    /// once, since the server has said it does not want more; a hiccup needs
    /// `tripAfter` in a row and a busy answer `busyTripAfter`, after which the
    /// rests lengthen from the shortest.
    public mutating func failed(_ failure: PrecacheFailure, now: Date, jitter: Double) {
        consecutive += 1
        last = failure
        let refused = failure == .throttled || failure == .blocked
        let busy = failure == .busy
        let threshold = busy ? Self.busyTripAfter : Self.tripAfter
        guard refused || consecutive >= threshold else { return }
        let attempts = busy ? consecutive - Self.busyTripAfter + 1 : consecutive
        let rest = PrecachePlan.retryDelaySeconds(failure, attempts: attempts, jitter: jitter)
        restingUntil = now.addingTimeInterval(TimeInterval(max(rest, 1)))
    }

    public func restLeft(now: Date) -> TimeInterval {
        max(restingUntil.map { $0.timeIntervalSince(now) } ?? 0, 0)
    }
}
