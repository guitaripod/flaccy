import Foundation
import RevenueCat

/// Mirrors each person's walk towards a purchase into RevenueCat subscriber
/// attributes. The trial lives in the Keychain and both paywalls are our own
/// views, so without this RevenueCat only ever hears from the people who paid
/// and a price change cannot be judged by anything but a handful of sales.
/// `scripts/rc-funnel.py` reads the attributes back as a funnel per price.
///
/// Counters are kept locally and re-sent whole, because attributes are last
/// write wins and the SDK only syncs a value that actually changed.
enum PurchaseFunnel {

    private enum Key: String {
        case buildConfig = "build_config"
        case trialStartedAt = "trial_started_at"
        case entitlement
        case paywallViews = "paywall_views"
        case paywallFirstSeenAt = "paywall_first_seen_at"
        case paywallLastSeenAt = "paywall_last_seen_at"
        case paywallLastPrice = "paywall_last_price"
        case paywallLastOffer = "paywall_last_offer"
        case paywallLastTrialDay = "paywall_last_trial_day"
        case checkoutsStarted = "checkouts_started"
        case checkoutsCancelled = "checkouts_cancelled"
        case checkoutLastPlan = "checkout_last_plan"
        case checkoutLastPrice = "checkout_last_price"
        case checkoutLastOutcome = "checkout_last_outcome"
        case libraryTracks = "library_tracks"
        case libraryFilledAt = "library_filled_at"
        case playedSample = "played_sample"
    }

    enum CheckoutOutcome: String {
        case purchased
        case pending
        case cancelled
        case failed
    }

    private static let counterPrefix = "flaccy.funnel."
    private static let libraryFilledKey = "flaccy.funnel.libraryFilled"
    private static let playedSampleKey = "flaccy.funnel.playedSample"
    private static var libraryObserver: NSObjectProtocol?

    #if DEBUG
    private static let buildConfig = "debug"
    #else
    private static let buildConfig = "release"
    #endif

    static func noteEntitlement(_ state: EntitlementState, trialStart: Date?) {
        var attributes: [Key: String] = [
            .buildConfig: buildConfig,
            .entitlement: label(for: state),
        ]
        if let trialStart {
            attributes[.trialStartedAt] = timestamp(trialStart)
        }
        send(attributes)
    }

    /// Follows the library's size in coarse buckets, and stamps once when the
    /// first song of the person's own arrives — together they say whether the
    /// people who leave on day one ever got their music in at all.
    static func observeLibrary() {
        guard libraryObserver == nil else { return }
        libraryObserver = NotificationCenter.default.addObserver(
            forName: Library.didUpdateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let sampleNames = SampleMusicService.sampleFileNames
                let own = Library.shared.allTracks.lazy
                    .filter { !SampleMusicService.isSample($0.fileURL, among: sampleNames) }
                    .count
                noteLibrary(ownTracks: own)
            }
        }
    }

    static func noteLibrary(ownTracks: Int) {
        guard canSend else { return }
        var attributes: [Key: String] = [.libraryTracks: bucket(ownTracks)]
        if ownTracks > 0, !UserDefaults.standard.bool(forKey: libraryFilledKey) {
            UserDefaults.standard.set(true, forKey: libraryFilledKey)
            attributes[.libraryFilledAt] = timestamp(Date())
        }
        send(attributes)
    }

    static func noteSamplePlayed() {
        guard canSend, !UserDefaults.standard.bool(forKey: playedSampleKey) else { return }
        UserDefaults.standard.set(true, forKey: playedSampleKey)
        send([.playedSample: "true"])
    }

    static func notePaywallShown(offer: PurchaseOffer?, state: EntitlementState) {
        let views = increment(.paywallViews)
        let now = timestamp(Date())
        var attributes: [Key: String] = [
            .buildConfig: buildConfig,
            .paywallViews: String(views),
            .paywallLastSeenAt: now,
            .paywallLastPrice: offer?.displayPrice ?? "unavailable",
            .paywallLastOffer: offer.map(offerLabel) ?? "none",
            .paywallLastTrialDay: trialDayLabel(for: state),
        ]
        if views == 1 {
            attributes[.paywallFirstSeenAt] = now
        }
        send(attributes)
    }

    static func noteCheckoutStarted(_ offer: PurchaseOffer) {
        send([
            .checkoutsStarted: String(increment(.checkoutsStarted)),
            .checkoutLastPlan: offerLabel(offer),
            .checkoutLastPrice: offer.displayPrice,
        ])
    }

    static func noteCheckoutFinished(_ outcome: CheckoutOutcome) {
        var attributes: [Key: String] = [.checkoutLastOutcome: outcome.rawValue]
        if outcome == .cancelled {
            attributes[.checkoutsCancelled] = String(increment(.checkoutsCancelled))
        }
        send(attributes)
    }

    /// The `--trial-day` clock is a fiction, so nothing it produces may reach
    /// the numbers a pricing decision is made from.
    private static var canSend: Bool {
        Purchases.isConfigured && !PurchaseManager.shared.trialClockIsOverridden
    }

    private static func send(_ attributes: [Key: String]) {
        guard canSend else { return }
        AppLogger.debug(
            "Funnel: \(attributes.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " "))",
            category: .purchases
        )
        Purchases.shared.attribution.setAttributes(
            Dictionary(uniqueKeysWithValues: attributes.map { ($0.key.rawValue, $0.value) })
        )
    }

    private static func increment(_ key: Key) -> Int {
        let defaults = UserDefaults.standard
        let value = defaults.integer(forKey: counterPrefix + key.rawValue) + 1
        defaults.set(value, forKey: counterPrefix + key.rawValue)
        return value
    }

    private static func bucket(_ tracks: Int) -> String {
        switch tracks {
        case ..<1: "0"
        case ..<50: "1-49"
        case ..<500: "50-499"
        case ..<5000: "500-4999"
        default: "5000+"
        }
    }

    private static func label(for state: EntitlementState) -> String {
        switch state {
        case .trialNotStarted: "not_started"
        case .trial: "trial"
        case .expired: "expired"
        case .purchased(let plan): plan.rawValue
        }
    }

    /// "d3" is the third trial day; "expired" covers the wall and the welcome-back window.
    private static func trialDayLabel(for state: EntitlementState) -> String {
        switch state {
        case .trialNotStarted: "not_started"
        case .trial(let daysRemaining): "d\(TrialRunway.lengthDays - daysRemaining + 1)"
        case .expired: "expired"
        case .purchased(let plan): plan.rawValue
        }
    }

    private static func offerLabel(_ offer: PurchaseOffer) -> String {
        offer.isWelcomeBack ? "\(offer.plan.rawValue)_welcome" : offer.plan.rawValue
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
