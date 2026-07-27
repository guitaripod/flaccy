import StoreKit
import UIKit

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
        guard defaults.string(forKey: versionKey) != currentVersion, let scene = activeScene else {
            return
        }
        defaults.set(currentVersion, forKey: versionKey)
        AppStore.requestReview(in: scene)
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
