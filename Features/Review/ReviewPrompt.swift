import MidgarCommerce
import MidgarCore
import StoreKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Asks for an App Store rating once the person has demonstrably got value out of Flaccy. `MidgarReviewPolicy` decides
/// whether an ask is due (the shared Midgar rules: not in the first days or sessions, not within 120 days of the last
/// ask or on the version that asked, not within a week of a failed purchase); this type reports each positive moment to
/// it and, when it says yes, asks StoreKit a beat later, only while nothing else is covering the window.
///
/// A "success" is a song played through to its natural end. A rating count is both a ranking input and the strongest
/// conversion signal on a product page, so nothing else is a reason to ask.
@MainActor
enum ReviewPrompt {

    static let askDelay: Duration = .milliseconds(1_500)

    /// Guards against a second success landing while the first ask is still delayed: without it, two songs ending
    /// within the same delay could each see themselves as due and both call StoreKit.
    private static var askPending = false

    nonisolated static let policy: MidgarReviewPolicy = {
        let storage = MidgarReviewFileStorage(appID: FlaccyMidgar.appID)
        LegacyReviewState.migrate(from: .standard, into: storage)
        return MidgarReviewPolicy(storage: storage)
    }()

    /// Counts one session. Call it once per launch.
    nonisolated static func beginSession() {
        policy.beginSession()
    }

    /// Call when a track plays through to its natural end (including a repeat-one loop; not a manual skip).
    static func recordSuccess() {
        guard policy.noteSuccess() else {
            MidgarLog.info("Review prompt skipped: \(policy.evaluate())", category: .ui)
            return
        }
        guard !askPending else {
            MidgarLog.info("Review prompt skipped: an ask is already pending", category: .ui)
            return
        }
        askPending = true
        Task {
            defer { askPending = false }
            try? await Task.sleep(for: askDelay)
            attemptAsk()
        }
    }

    private static func attemptAsk() {
        guard requestReview() else {
            MidgarLog.info("Review prompt deferred (no eligible window)", category: .ui)
            return
        }
        policy.notePrompted()
        MidgarLog.info("Requested App Store review", category: .ui)
    }

    /// Presents the system rating sheet, reporting whether it could actually be shown. On iOS anything already
    /// presented over the root, the reminder opt-in alert above all, wins, so the two never stack.
    private static func requestReview() -> Bool {
        #if canImport(UIKit)
        guard let scene = activeScene, !hasPresentedViewController(in: scene) else { return false }
        AppStore.requestReview(in: scene)
        return true
        #else
        guard NSApp.isActive,
              let window = NSApp.mainWindow,
              window.attachedSheet == nil,
              let controller = window.contentViewController
        else { return false }
        AppStore.requestReview(in: controller)
        return true
        #endif
    }

    #if canImport(UIKit)
    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    private static func hasPresentedViewController(in scene: UIWindowScene) -> Bool {
        scene.keyWindow?.rootViewController?.presentedViewController != nil
    }
    #endif
}
