import Foundation
import MidgarCommerce

/// The ask history the app kept before `MidgarReviewPolicy`: a list of ask dates with success counters, and before that
/// a "prompted on this version" flag. A person who was asked recently must not be asked again the day the policy
/// changes, so the newest ask becomes the policy's last prompt the first time it runs. A flag without a date is treated
/// as an ask made at the migration, which delays the next ask rather than permitting one early. The counters only fed
/// the retired eligibility rules, so they are removed with the history.
nonisolated enum LegacyReviewState {
    static let askDatesKey = "flaccy.review.askDates"
    static let promptedVersionKey = "flaccy.review.promptedVersion"
    static let retiredKeys = [
        "flaccy.review.successCount", "flaccy.review.successCountAtLastAsk", "flaccy.review.legacyStateCleared",
        "flaccy.review.importedTracks", "flaccy.review.completedPlays", "flaccy.review.listeningDays",
        "flaccy.review.lifetimePurchased",
    ]
    static let migratedKey = "flaccy.review.migratedToMidgar"

    static func migrate(from defaults: UserDefaults, into storage: any MidgarReviewStorage, now: Date = Date()) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        let lastAsk = newestAsk(in: defaults, now: now)
        retire(in: defaults)
        guard let lastAsk else { return }
        var state = storage.load()
        guard state.lastPrompt == nil else { return }
        state.lastPrompt = lastAsk
        storage.save(state)
    }

    private static func newestAsk(in defaults: UserDefaults, now: Date) -> Date? {
        let dates = defaults.array(forKey: askDatesKey) as? [Date] ?? []
        let undated = defaults.string(forKey: promptedVersionKey) != nil ? [now] : []
        return (dates + undated).max()
    }

    /// Removes the values only the retired mechanism read, once the policy holds what they said.
    private static func retire(in defaults: UserDefaults) {
        for key in [askDatesKey, promptedVersionKey] + retiredKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
