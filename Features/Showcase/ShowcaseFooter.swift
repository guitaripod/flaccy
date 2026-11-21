import Foundation

/// What the showcase offers at its foot to one person: a line about where their trial or purchase stands, the main
/// button, and a second button when there is another way on. Someone whose trial has ended is led to the plans;
/// everyone else is led to their music, with the plans one tap away while a trial runs or a second look waits.
nonisolated struct ShowcaseFooter: Equatable, Sendable {

    enum Action: Equatable, Sendable {
        case listen
        case plans
    }

    let status: String?
    /// Whether the status line is news that changes what the person does next (the trial has ended, free days
    /// are waiting) and is set as prominently as the page's own text, not as a quiet note under the rows.
    let statusLeads: Bool
    let primaryTitle: String
    let primary: Action
    let secondaryTitle: String?
    let secondary: Action?

    /// The foot for an entitlement state, or the plain one while the store has not answered yet.
    @MainActor
    static func make(for state: EntitlementState?) -> ShowcaseFooter {
        guard let state else {
            return ShowcaseFooter(
                status: nil, statusLeads: false, primaryTitle: ShowcaseCopy.proceed, primary: .listen,
                secondaryTitle: nil, secondary: nil
            )
        }
        let status = PaywallCopy.statusLine(for: state)
        switch state {
        case .expired:
            return ShowcaseFooter(
                status: status, statusLeads: true, primaryTitle: ShowcaseCopy.seePlans, primary: .plans,
                secondaryTitle: ShowcaseCopy.notNow, secondary: .listen
            )
        case .trial, .secondLookReady:
            return ShowcaseFooter(
                status: status, statusLeads: state == .secondLookReady, primaryTitle: ShowcaseCopy.proceed, primary: .listen,
                secondaryTitle: ShowcaseCopy.seePlans, secondary: .plans
            )
        case .trialNotStarted, .purchased:
            return ShowcaseFooter(
                status: status, statusLeads: false, primaryTitle: ShowcaseCopy.proceed, primary: .listen,
                secondaryTitle: nil, secondary: nil
            )
        }
    }

    /// The foot for the person using this device now.
    @MainActor
    static var current: ShowcaseFooter {
        let purchases = PurchaseManager.shared
        return make(for: purchases.hasLoadedEntitlements ? purchases.state : nil)
    }
}
