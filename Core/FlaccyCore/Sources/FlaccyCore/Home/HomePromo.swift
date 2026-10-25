import Foundation

/// The one card Home spends on getting music in and on Flaccy Pro, decided
/// from the entitlement and the library. It never opens a paywall by itself
/// (App Review rejects that): every card only offers one, on a tap. Linux has
/// no purchase and shows none of these.
public enum HomePromo: Equatable, Sendable {
    /// No music of the person's own yet: Home leads with adding it, or the sample album.
    case getStarted
    /// Their music is in and the trial waits for its first play.
    case trialStartsOnFirstPlay
    /// Mid-trial, once Flaccy has done enough for the library to show it.
    case trialValue(daysRemaining: Int)
    /// The final day of the trial.
    case lastDay
    /// The trial ended; the welcome-back price applies while its window is open.
    case keepListening(welcomeBack: Bool)

    public enum Phase: Equatable, Sendable {
        case notStarted
        case trial(daysRemaining: Int)
        case expired
        case purchased
    }

    public enum Placement: Equatable, Sendable {
        case replacesHero
        case belowHero
        case heroFootnote
        case pageEnd
    }

    public struct Facts: Equatable, Sendable {
        public var phase: Phase
        public var entitlementsLoaded: Bool
        public var ownTrackCount: Int
        public var welcomeBackOpen: Bool
        public var proofLineCount: Int

        public init(phase: Phase, entitlementsLoaded: Bool, ownTrackCount: Int, welcomeBackOpen: Bool, proofLineCount: Int) {
            self.phase = phase
            self.entitlementsLoaded = entitlementsLoaded
            self.ownTrackCount = ownTrackCount
            self.welcomeBackOpen = welcomeBackOpen
            self.proofLineCount = proofLineCount
        }
    }

    /// The value card waits until the library has at least this much to show for the trial.
    public static let valueCardMinimumProofLines = 2
    /// ...and until this many trial days have passed, so day one is never a sales pitch.
    public static let valueCardAfterDays = 2

    /// Nil when Home should sell nothing: paid, or an ended trial that the
    /// entitlements have not confirmed yet (the local clock alone says
    /// "expired" for the first second of every launch, paid or not).
    public static func card(for facts: Facts) -> HomePromo? {
        guard facts.ownTrackCount > 0 else { return .getStarted }
        switch facts.phase {
        case .purchased:
            return nil
        case .notStarted:
            return .trialStartsOnFirstPlay
        case .trial(let daysRemaining):
            if daysRemaining <= TrialRunway.runwayBannerAtDaysRemaining { return .lastDay }
            let elapsed = TrialRunway.lengthDays - daysRemaining
            guard elapsed >= valueCardAfterDays, facts.proofLineCount >= valueCardMinimumProofLines else { return nil }
            return .trialValue(daysRemaining: daysRemaining)
        case .expired:
            return facts.entitlementsLoaded ? .keepListening(welcomeBack: facts.welcomeBackOpen) : nil
        }
    }

    public var placement: Placement {
        switch self {
        case .getStarted, .keepListening: .replacesHero
        case .lastDay: .belowHero
        case .trialStartsOnFirstPlay: .heroFootnote
        case .trialValue: .pageEnd
        }
    }
}
