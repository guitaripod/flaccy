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
/// product page. Two independent gates open the prompt: cumulative tracks imported (someone who
/// drags their whole collection in once has got the app's entire value) or tracks played through
/// to the scrobble threshold across at least two different days (a listener who came back).
@MainActor
enum ReviewPrompt {
    private static let tracksBeforeAsking = 20
    private static let playsBeforeAsking = 25
    private static let listeningDaysBeforeAsking = 2

    private static let importCountKey = "flaccy.review.importedTracks"
    private static let playCountKey = "flaccy.review.completedPlays"
    private static let playDaysKey = "flaccy.review.listeningDays"
    private static let versionKey = "flaccy.review.promptedVersion"

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
        guard plays >= playsBeforeAsking, days.count >= listeningDaysBeforeAsking else { return }
        askIfDue()
    }

    private static func askIfDue() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: versionKey) != currentVersion, requestReview() else { return }
        defaults.set(currentVersion, forKey: versionKey)
        AppLogger.info("Requested App Store review for \(currentVersion)", category: .ui)
    }

    /// Presents the system rating sheet, reporting whether it could actually be shown.
    private static func requestReview() -> Bool {
        #if canImport(UIKit)
        guard let scene = activeScene else { return false }
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
    #endif

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
