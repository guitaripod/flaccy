import Foundation

/// The job's circuit breaker: what each finished attempt says about whether the
/// next one is worth making.
///
/// The decisions are pure so they can be proved without a network, a database
/// or an actor. A run of silence parks the pass until the route changes; a run
/// of error answers gives the service a breather; a spent daily allowance
/// stops the scope on the first sign of it, because no retry can help before
/// the reset; and an attempt the sources really did answer proves the route
/// works and clears every run.
public struct EnrichmentBreaker: Sendable {

    public enum Observation: Sendable, Equatable {
        case progress
        case transport
        case unauthorized
        case quotaReached(resetsAt: Date)
        case serviceError
    }

    public enum Verdict: Sendable, Equatable {
        case carryOn
        case waitForNetwork
        case needsEntitlement
        case pause(EnrichmentJobProgress.Activity, until: Date)
    }

    private var transportRun = 0
    private var serviceRun = 0

    public init() {}

    /// A scope starts with a clean slate: a run of failures in the album scope
    /// says nothing about the artist scope behind it.
    public mutating func reset() {
        transportRun = 0
        serviceRun = 0
    }

    public mutating func observe(_ observation: Observation, now: Date) -> Verdict {
        switch observation {
        case .progress:
            reset()
            return .carryOn

        case .unauthorized:
            return .needsEntitlement

        case .transport:
            serviceRun = 0
            transportRun += 1
            return transportRun >= EnrichmentPolicy.transportFailuresBeforeWaiting ? .waitForNetwork : .carryOn

        case .serviceError:
            transportRun = 0
            serviceRun += 1
            guard serviceRun >= EnrichmentPolicy.transportFailuresBeforeWaiting else { return .carryOn }
            return .pause(.serviceUnavailable, until: now.addingTimeInterval(EnrichmentPolicy.serviceRetryInterval))

        case .quotaReached(let resetsAt):
            reset()
            return .pause(.dailyLimit, until: resetsAt)
        }
    }
}
