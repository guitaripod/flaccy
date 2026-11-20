import Foundation
import MidgarCore

/// What Home's first frame waits for, so a launch opens on the page the person
/// will keep seeing instead of one that rearranges itself a moment later: the
/// library a previous launch indexed, the queue it saved (Continue leads Home
/// whenever there is one to pick up) and the entitlements, which decide
/// whether a card stands where the hero would. The entitlements get only a
/// short wait once everything else is back, so a slow store never holds a
/// page that is otherwise ready. Shared by the iPhone, iPad and Mac Homes.
@MainActor
final class HomeLaunchGate {

    static let entitlementPatience: TimeInterval = 1

    /// The notifications that can open the gate; Home rebuilds on each.
    static let openingNotifications: [Notification.Name] = [
        Library.didUpdateNotification,
        AudioPlayer.queueRestoreDidFinish,
        PurchaseManager.entitlementsDidLoad,
    ]

    private let onPatienceSpent: () -> Void
    private var waitingForEntitlementsSince: Date?
    private var hasLogged = false
    private let began = Date()

    init(onPatienceSpent: @escaping () -> Void) {
        self.onPatienceSpent = onPatienceSpent
    }

    /// Whether the first frame should still wait. Asked before each first-frame
    /// build; once it answers false it is not asked again.
    var isHolding: Bool {
        if Library.shared.isRestoringIndexedLibrary || AudioPlayer.shared.isRestoringQueue { return true }
        if PurchaseManager.shared.hasLoadedEntitlements || hasSpentPatience { return opened() }
        return true
    }

    private var hasSpentPatience: Bool {
        guard let since = waitingForEntitlementsSince else {
            startWaitingForEntitlements()
            return false
        }
        return Date().timeIntervalSince(since) >= Self.entitlementPatience
    }

    private func startWaitingForEntitlements() {
        waitingForEntitlementsSince = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.entitlementPatience) { [weak self] in
            self?.onPatienceSpent()
        }
    }

    private func opened() -> Bool {
        if !hasLogged {
            hasLogged = true
            let milliseconds = Int(Date().timeIntervalSince(began) * 1_000)
            let entitlements = PurchaseManager.shared.hasLoadedEntitlements ? "loaded" : "still loading"
            MidgarLog.info("Home launch gate opened after \(milliseconds) ms, entitlements \(entitlements)", category: .performance)
        }
        return false
    }
}
