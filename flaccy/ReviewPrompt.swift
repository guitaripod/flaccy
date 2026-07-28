import StoreKit
#if canImport(UIKit)
import UIKit
#endif

/// Asks for an App Store rating once the user has a real library in Flaccy, and at most once per
/// app version.
///
/// Rating count is both an App Store ranking input and the strongest conversion signal on a
/// product page, and Flaccy shipped with no way to request one. The gate is cumulative tracks
/// successfully imported rather than a count of import *sessions*: someone who drags their whole
/// collection in once has got the app's entire value and might never import again.
@MainActor
enum ReviewPrompt {
    private static let tracksBeforeAsking = 20
    private static let countKey = "flaccy.review.importedTracks"
    private static let versionKey = "flaccy.review.promptedVersion"

    /// Call when an import finishes, with the number of tracks it actually added.
    static func recordImportedTracks(_ imported: Int) {
        guard imported > 0 else { return }
        let defaults = UserDefaults.standard
        let total = defaults.integer(forKey: countKey) + imported
        defaults.set(total, forKey: countKey)

        guard total >= tracksBeforeAsking else { return }
        guard defaults.string(forKey: versionKey) != currentVersion, requestReview() else { return }
        defaults.set(currentVersion, forKey: versionKey)
    }

    /// Presents the system rating sheet, reporting whether it could actually be shown. The macOS
    /// client has no equivalent entry point yet, so it never marks the version as prompted.
    private static func requestReview() -> Bool {
        #if canImport(UIKit)
        guard let scene = activeScene else { return false }
        AppStore.requestReview(in: scene)
        return true
        #else
        return false
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
