import StoreKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Asks for an App Store rating once the person has demonstrably got value out of Flaccy, and
/// at most once per app version.
///
/// Rating count is both an App Store ranking input and the strongest conversion signal on a
/// product page. Two independent gates open the prompt: cumulative tracks imported (someone with
/// a handful of their own files in the library has crossed this app's one real onboarding step)
/// or tracks played through to the scrobble threshold (a listener who is actually listening).
/// Both are deliberately shallow, because the deep thresholds they replaced were reached by
/// almost nobody: the median install never returns for a second day.
@MainActor
enum ReviewPrompt {
    private static let tracksBeforeAsking = 5
    private static let playsBeforeAsking = 8
    private static let listeningDaysBeforeAsking = 1

    private static let importCountKey = "flaccy.review.importedTracks"
    private static let playCountKey = "flaccy.review.completedPlays"
    private static let playDaysKey = "flaccy.review.listeningDays"
    private static let versionKey = "flaccy.review.promptedVersion"
    private static let lifetimePurchasedKey = "flaccy.review.lifetimePurchased"

    /// Call once a lifetime unlock has landed from a purchase or a restore: someone who has
    /// just paid once for good is the listener most likely to say why. The paywall is still on
    /// screen at this moment and the rating sheet will not stack on it, so the ask is retried
    /// shortly after — and if that too is too early, the flag leaves the next completed play
    /// to carry it.
    static func recordLifetimePurchase() {
        UserDefaults.standard.set(true, forKey: lifetimePurchasedKey)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard UserDefaults.standard.bool(forKey: lifetimePurchasedKey) else { return }
            if askIfDue() { UserDefaults.standard.removeObject(forKey: lifetimePurchasedKey) }
        }
    }

    /// Call when an import finishes, with the number of tracks it actually added.
    static func recordImportedTracks(_ imported: Int) {
        guard imported > 0 else { return }
        let defaults = UserDefaults.standard
        let total = defaults.integer(forKey: importCountKey) + imported
        defaults.set(total, forKey: importCountKey)
        guard total >= tracksBeforeAsking else { return }
        askIfDue()
    }

    /// Call when a track has played far enough to count as a listen.
    static func recordCompletedPlay() {
        let defaults = UserDefaults.standard
        let plays = defaults.integer(forKey: playCountKey) + 1
        defaults.set(plays, forKey: playCountKey)

        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate
        var days = defaults.array(forKey: playDaysKey) as? [Double] ?? []
        if days.last != today {
            days.append(today)
            defaults.set(days, forKey: playDaysKey)
        }
        let earnedByListening = plays >= playsBeforeAsking && days.count >= listeningDaysBeforeAsking
        let earnedByPurchase = defaults.bool(forKey: lifetimePurchasedKey)
        guard earnedByListening || earnedByPurchase else { return }
        if askIfDue(), earnedByPurchase {
            defaults.removeObject(forKey: lifetimePurchasedKey)
        }
    }

    /// Asks unless this version already has, and reports whether the matter is
    /// settled — asked now, or asked before — so a one-shot trigger knows
    /// whether to keep waiting for a moment when the sheet can be shown.
    @discardableResult
    private static func askIfDue() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: versionKey) != currentVersion else { return true }
        guard requestReview() else { return false }
        defaults.set(currentVersion, forKey: versionKey)
        AppLogger.info("Requested App Store review for \(currentVersion)", category: .ui)
        return true
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
        guard NSApp.isActive else { return false }
        SKStoreReviewController.requestReview()
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

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
