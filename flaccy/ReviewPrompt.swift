import StoreKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Asks for an App Store rating once the person has demonstrably got value out
/// of Flaccy, and again later if the first ask went nowhere.
///
/// A "success" is a song played through to its natural end. The eligibility
/// decision itself (`isEligible`) is a pure function of the stored counters
/// and ask history, so it can be tested without UserDefaults or the StoreKit
/// sheet; only `recordSuccess` and `attemptAsk` touch either.
@MainActor
enum ReviewPrompt {

    private static let successesBeforeFirstAsk = 2
    private static let minimumDaysBetweenAsks = 14.0
    private static let minimumNewSuccessesBetweenAsks = 3
    private static let maximumAsksPerRollingYear = 3
    private static let rollingYear: TimeInterval = 365 * 86_400
    private static let askDelayAfterSuccess: TimeInterval = 1.5

    private static let successCountKey = "flaccy.review.successCount"
    private static let askDatesKey = "flaccy.review.askDates"
    private static let successCountAtLastAskKey = "flaccy.review.successCountAtLastAsk"
    private static let legacyStateClearedKey = "flaccy.review.legacyStateCleared"

    /// Call when a track plays through to its natural end (including a
    /// repeat-one loop; not a manual skip).
    static func recordSuccess() {
        clearLegacyStateIfNeeded()
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: successCountKey) + 1
        defaults.set(count, forKey: successCountKey)

        guard isEligible(
            successCount: count,
            askDates: storedAskDates(),
            successCountAtLastAsk: defaults.integer(forKey: successCountAtLastAskKey),
            now: Date()
        ) else {
            AppLogger.info("Review prompt skipped at success #\(count) (not eligible)", category: .ui)
            return
        }

        Task {
            try? await Task.sleep(for: .seconds(askDelayAfterSuccess))
            attemptAsk(successCount: count)
        }
    }

    /// Whether an ask is due right now, given nothing but the stored history.
    /// The first ask needs only two successes; every ask after that needs
    /// both 14 days and 3 fresh successes since the previous one, and no ask
    /// at all is due once 3 asks already fall inside the trailing 365 days.
    static func isEligible(
        successCount: Int, askDates: [Date], successCountAtLastAsk: Int, now: Date
    ) -> Bool {
        guard successCount >= successesBeforeFirstAsk else { return false }
        let askDatesInRollingYear = askDates.filter { now.timeIntervalSince($0) < rollingYear }
        guard askDatesInRollingYear.count < maximumAsksPerRollingYear else { return false }
        guard let mostRecentAsk = askDates.max() else { return true }
        let daysSinceLastAsk = now.timeIntervalSince(mostRecentAsk) / 86_400
        let newSuccessesSinceLastAsk = successCount - successCountAtLastAsk
        return daysSinceLastAsk >= minimumDaysBetweenAsks
            && newSuccessesSinceLastAsk >= minimumNewSuccessesBetweenAsks
    }

    private static func attemptAsk(successCount: Int) {
        guard requestReview() else {
            AppLogger.info("Review prompt deferred at success #\(successCount) (no eligible window)", category: .ui)
            return
        }
        let defaults = UserDefaults.standard
        let dates = storedAskDates() + [Date()]
        defaults.set(dates, forKey: askDatesKey)
        defaults.set(successCount, forKey: successCountAtLastAskKey)
        AppLogger.info("Requested App Store review (ask #\(dates.count), success #\(successCount))", category: .ui)
    }

    private static func storedAskDates() -> [Date] {
        UserDefaults.standard.array(forKey: askDatesKey) as? [Date] ?? []
    }

    /// The old mechanism (20 imports, or 25 scrobble-threshold plays across 2
    /// days, or a lifetime purchase, asked once per version) kept only the
    /// last-prompted version string, never a date — so there is no ask history
    /// to carry into `askDates`. This just stops the old keys from being read.
    private static func clearLegacyStateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: legacyStateClearedKey) else { return }
        for key in [
            "flaccy.review.importedTracks", "flaccy.review.completedPlays",
            "flaccy.review.listeningDays", "flaccy.review.promptedVersion",
            "flaccy.review.lifetimePurchased",
        ] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: legacyStateClearedKey)
    }

    /// Presents the system rating sheet, reporting whether it could actually be
    /// shown. On iOS anything already presented over the root — the reminder
    /// opt-in alert above all — wins, so the two never stack.
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
