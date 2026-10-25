import Foundation
import MidgarCommerce
import MidgarCore
import Security
#if os(macOS)
import AppKit
#else
import UIKit
#endif

nonisolated enum PurchasePlan: String, Equatable, Hashable, Sendable {
    case yearly
    case lifetime
}

nonisolated enum EntitlementState: Equatable, Hashable {
    /// Nothing of the person's own has played yet, so the trial is not counting.
    case trialNotStarted
    case trial(daysRemaining: Int)
    case expired
    case purchased(PurchasePlan)

    var isPurchased: Bool {
        if case .purchased = self { return true }
        return false
    }
}

/// One buyable plan as the paywall renders it: the App Store product with its
/// localized price. A welcome-back offer is the lifetime plan sold as its own
/// product, and carries the regular price only when that comparison is honest —
/// same currency, and actually lower.
struct PurchaseOffer: Equatable {
    let plan: PurchasePlan
    let storeProduct: StoreProduct
    var isWelcomeBack = false
    var regularPrice: String? = nil

    var displayPrice: String { storeProduct.displayPrice }

    static func == (lhs: PurchaseOffer, rhs: PurchaseOffer) -> Bool {
        lhs.plan == rhs.plan
            && lhs.isWelcomeBack == rhs.isWelcomeBack
            && lhs.storeProduct.id == rhs.storeProduct.id
    }
}

#if os(macOS)
typealias PurchaseAnchor = NSWindow
#else
typealias PurchaseAnchor = UIScene
#endif

/// Entitlement source of truth for the Apple clients, backed by `MidgarStore`.
///
/// MidgarStore buys, verifies and finishes on StoreKit 2 and reports every
/// transaction to the Midgar ledger. The seven-day
/// trial stays local because it starts before any purchase exists and must
/// survive a reinstall, which the Keychain gives us for free; it starts at the
/// first play of the person's own music, not at install. The yearly
/// subscription and the lifetime unlock both grant `pro`, so one boolean
/// answers "may this person play music". Everything the runway needs — which
/// day it is, whether the banner is due, whether the welcome-back window is
/// open — derives from the one stored start date through `TrialRunway`, so the
/// clients never do their own arithmetic.
final class PurchaseManager {

    static let shared = PurchaseManager(store: FlaccyMidgar.shared.store)

    static let stateDidChange = Notification.Name("PurchaseStateDidChange")
    static let paywallRequired = Notification.Name("PaywallRequired")
    static let entitlementsDidLoad = Notification.Name("PurchaseEntitlementsDidLoad")

    static let trialLengthDays = TrialRunway.lengthDays

    private(set) var state: EntitlementState = .trialNotStarted
    private(set) var offers: [PurchaseOffer] = []
    private(set) var trialStart = Date()
    private(set) var trialHasStarted = false
    private var trialStartIsUnreadable = false
    private(set) var hasLoadedEntitlements = false
    private var welcomeProductSeenThisSession = false
    private var welcomeProduct: StoreProduct?
    private var runwayPromptShownCached = false

    private var storeEventsTask: Task<Void, Never>?

    private static let welcomeProductSeenKey = "flaccy.lapsedOfferingSeen"

    #if DEBUG
    private var trialDayOverrideActive = false
    #endif

    /// True only under the DEBUG `--trial-day` flag, when the clock is a fiction
    /// and nothing durable — Keychain stamps, real notifications — may follow from it.
    var trialClockIsOverridden: Bool {
        #if DEBUG
        trialDayOverrideActive
        #else
        false
        #endif
    }

    /// The welcome-back product, once the App Store has returned it, is
    /// remembered across launches so an offline consent or foreground still
    /// schedules the welcome-back reminder.
    var lapsedOfferExists: Bool {
        welcomeProductSeenThisSession || UserDefaults.standard.bool(forKey: Self.welcomeProductSeenKey)
    }

    /// The welcome-back lifetime plan, built at read time so "Usually <regular>"
    /// reflects the regular price whenever it has loaded, not whenever the
    /// welcome-back product happened to arrive.
    var lapsedLifetimeOffer: PurchaseOffer? {
        guard let welcomeProduct else { return nil }
        return PurchaseOffer(
            plan: .lifetime,
            storeProduct: welcomeProduct,
            isWelcomeBack: true,
            regularPrice: Self.regularPrice(against: lifetimeOffer?.storeProduct, welcome: welcomeProduct)
        )
    }

    /// The purchase engine, absent in a test host or a screenshot seed.
    private let store: MidgarStore?

    init(store: MidgarStore?) {
        self.store = store
    }

    /// An `expired` state derived before the entitlements have loaded is only
    /// the local trial clock talking, and the answer arrives within a second
    /// for someone who already paid, so playback is never refused on it.
    var allowsPlayback: Bool {
        state != .expired || !hasLoadedEntitlements
    }

    var yearlyOffer: PurchaseOffer? { offers.first { $0.plan == .yearly } }
    var lifetimeOffer: PurchaseOffer? { offers.first { $0.plan == .lifetime } }

    var runwayPhase: TrialRunway.Phase {
        TrialRunway.phase(start: trialStart, now: Date())
    }

    var lapsedOfferState: TrialRunway.LapsedOffer {
        guard hasLoadedEntitlements, state == .expired else { return .notYet }
        return TrialRunway.lapsedOffer(start: trialStart, now: Date())
    }

    var lifetimeOfferToPresent: PurchaseOffer? {
        guard !state.isPurchased else { return nil }
        if case .available = lapsedOfferState, let welcomeBack = lapsedLifetimeOffer {
            return welcomeBack
        }
        return lifetimeOffer
    }

    var offersToPresent: [PurchaseOffer] {
        [lifetimeOfferToPresent, yearlyOffer].compactMap { $0 }
    }

    /// The phase is checked before the Keychain is, and the add-only stamp is
    /// remembered once read true, so an activation edge on day one costs nothing.
    var runwayBannerIsDue: Bool {
        guard hasLoadedEntitlements, case .trial = state else { return false }
        guard case .trial(let daysRemaining) = runwayPhase,
              daysRemaining <= TrialRunway.runwayBannerAtDaysRemaining
        else { return false }
        return !runwayPromptHasBeenShown
    }

    private var runwayPromptHasBeenShown: Bool {
        if runwayPromptShownCached { return true }
        runwayPromptShownCached = TrialClock.date(for: .runwayPromptShown) != nil
        return runwayPromptShownCached
    }

    var reminderOptInIsDue: Bool {
        guard hasLoadedEntitlements, case .trial = state,
              !TrialReminderScheduler.shared.hasBeenAsked
        else { return false }
        return TrialRunway.consentWindowIsOpen(phase: runwayPhase)
    }

    func start() {
        readTrialStartIfNeeded()
        #if DEBUG
        applyTrialDayOverride()
        #endif
        setState(trialState())
        listenForStoreEvents()
        Task {
            await refresh()
            await TrialReminderScheduler.shared.refresh()
        }
        Task { await store?.reportPurchaseHistory() }
    }

    /// The trial starts at the first play of the person's own music, never at
    /// install, so a launch only ever reads the stored start. A launch before
    /// first unlock cannot read it (errSecInteractionNotAllowed), so the read is
    /// retried at every later chance and the state re-derived from it.
    private func readTrialStartIfNeeded() {
        guard !trialHasStarted else { return }
        switch TrialClock.lookup(.trialStart) {
        case .found(let start):
            trialStart = start
            trialHasStarted = true
            trialStartIsUnreadable = false
        case .absent:
            trialStartIsUnreadable = false
        case .unreadable(let status):
            trialStartIsUnreadable = true
            MidgarLog.notice("Trial start not readable from the Keychain yet (status \(status)); will retry", category: .purchases)
        }
    }

    /// Starts the trial the first time the person's own music plays — not at
    /// install, and not for the sample album — so the days it takes to get a
    /// library onto the device are never spent from it. The stamp is add-only
    /// like every trial date, so it can never move once written, and it is
    /// written even after a purchase so a lapsed subscription still has a start.
    func noteTrackStarted(_ track: Track) {
        guard !trialHasStarted, !trialClockIsOverridden else { return }
        guard !SampleMusicService.isSample(track.fileURL) else { return }
        guard case .absent = TrialClock.lookup(.trialStart) else {
            refreshTrialPhase()
            return
        }
        TrialClock.stampIfAbsent(Date(), for: .trialStart)
        readTrialStartIfNeeded()
        guard trialHasStarted else { return }
        MidgarLog.info("Trial started at the first play of the library's own music", category: .purchases)
        refreshTrialPhase()
        Task { await TrialReminderScheduler.shared.refresh() }
    }

    /// Called by both paywalls once their offers have loaded, and recorded with
    /// the schema's generic `paywall` placement because both are one view
    /// whichever surface opens them. The `--trial-day` clock is a fiction, so
    /// nothing it produces reaches the counts a pricing decision is made from.
    func notePaywallShown() {
        guard !trialClockIsOverridden else { return }
        Task { await MidgarSignals.shared?.record("paywall.view", props: ["placement": "paywall"]) }
    }

    /// Re-derives the trial day from the stored start, for a process that has
    /// lived across midnight; a purchase is never touched.
    func refreshTrialPhase() {
        guard !state.isPurchased else { return }
        readTrialStartIfNeeded()
        setState(trialState())
    }

    #if DEBUG
    /// `--trial-day N` (1…40) moves the trial clock in memory only, so every day
    /// of the runway can be exercised and screenshotted without touching the
    /// Keychain that the real trial lives in. Day N means N − 1 days elapsed:
    /// day 7 is the last trial day (banner due), day 9 opens the welcome-back window.
    private func applyTrialDayOverride() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--trial-day"),
              arguments.indices.contains(flag + 1),
              let day = Int(arguments[flag + 1]),
              (1...40).contains(day)
        else { return }
        trialStart = Date().addingTimeInterval(-TimeInterval(day - 1) * TrialRunway.day)
        trialHasStarted = true
        trialDayOverrideActive = true
        MidgarLog.info("Trial clock overridden: day \(day) (elapsed \(day - 1) d)", category: .purchases)
    }
    #endif

    /// Reads StoreKit and the ledger again. Without a store (a test host or a
    /// screenshot seed) the trial clock alone decides.
    func refresh() async {
        guard let store else {
            refreshTrialPhase()
            noteEntitlementsLoaded()
            return
        }
        await store.refresh()
        apply(await store.entitlements)
        await loadLapsedOfferIfNeeded()
    }

    @discardableResult
    func loadOffersIfNeeded() async -> [PurchaseOffer] {
        if !offers.isEmpty { return offers }
        guard let store else { return [] }
        do {
            let products = try await store.products()
            noteWelcomeProduct(in: products)
            var loaded: [PurchaseOffer] = []
            if let yearly = products.first(where: { $0.id == FlaccyProducts.yearly }) {
                loaded.append(PurchaseOffer(plan: .yearly, storeProduct: yearly))
            }
            if let lifetime = products.first(where: { $0.id == FlaccyProducts.lifetime }) {
                loaded.append(PurchaseOffer(plan: .lifetime, storeProduct: lifetime))
            }
            guard !loaded.isEmpty else {
                MidgarLog.notice("The App Store returned none of Flaccy's plans", category: .purchases)
                return []
            }
            offers = loaded
            MidgarLog.info(
                "Loaded offers: \(loaded.map { "\($0.plan.rawValue)=\($0.displayPrice)" }.joined(separator: ", ")) (welcome back: \(lapsedOfferExists))",
                category: .purchases
            )
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        } catch {
            MidgarLog.error("Offers load failed: \(error)", category: .purchases)
        }
        return offers
    }

    /// Every products fetch records whether the welcome-back product exists and
    /// keeps it, so the welcome-back price needs no second round trip when the
    /// window opens.
    private func noteWelcomeProduct(in products: [StoreProduct]) {
        let product = products.first { $0.id == FlaccyProducts.welcomeLifetime }
        if product != nil {
            welcomeProductSeenThisSession = true
            UserDefaults.standard.set(true, forKey: Self.welcomeProductSeenKey)
        }
        let changed = (welcomeProduct == nil) != (product == nil)
        welcomeProduct = product
        if changed {
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        }
    }

    /// The welcome-back lifetime product is only surfaced while its window is
    /// open for an expired trial (`lifetimeOfferToPresent` gates on that), and
    /// is fetched again only when no products fetch has captured it yet.
    func loadLapsedOfferIfNeeded() async {
        await loadOffersIfNeeded()
        refreshTrialPhase()
        guard case .available = lapsedOfferState, welcomeProduct == nil, let store else { return }
        do {
            noteWelcomeProduct(in: try await store.products())
            guard let offer = lapsedLifetimeOffer else {
                MidgarLog.info("Welcome-back window open but the App Store has no welcome-back product", category: .purchases)
                return
            }
            MidgarLog.info(
                "Loaded welcome-back offer: \(offer.displayPrice) (usually \(offer.regularPrice ?? "unknown"))",
                category: .purchases
            )
        } catch {
            MidgarLog.error("Welcome-back product load failed: \(error)", category: .purchases)
        }
    }

    /// "Usually <regular>" is only honest when both prices are quoted in the same
    /// known currency and the welcome-back price is actually lower.
    private static func regularPrice(against regular: StoreProduct?, welcome: StoreProduct) -> String? {
        guard let regular,
              let currency = regular.currencyCode,
              currency == welcome.currencyCode,
              welcome.price < regular.price
        else { return nil }
        return regular.displayPrice
    }

    enum PurchaseOutcome {
        case purchased
        case pending
        case cancelled
    }

    /// Buys the offer's product with the confirmation sheet anchored to `anchor`,
    /// the paywall's scene or window.
    func purchase(_ offer: PurchaseOffer, confirmIn anchor: PurchaseAnchor?) async throws -> PurchaseOutcome {
        guard let store else { throw PurchaseFailure.other }
        let productID = offer.storeProduct.id
        let result: MidgarPurchaseResult
        do {
            if let anchor {
                result = try await store.purchase(productID, confirmIn: anchor)
            } else {
                result = try await store.purchase(productID)
            }
        } catch let error as MidgarStoreError where PurchaseFailure.isCancellation(error) {
            MidgarLog.info("Purchase cancelled by user", category: .purchases)
            return .cancelled
        } catch let error as MidgarStoreError {
            MidgarLog.error("Purchase of \(productID) failed: \(error)", category: .purchases)
            throw PurchaseFailure(error)
        }
        switch result {
        case .purchased:
            apply(await store.entitlements)
            if !state.isPurchased {
                MidgarLog.error("Purchase of \(productID) completed without granting \(FlaccyProducts.entitlement)", category: .purchases)
            }
            MidgarLog.info(
                "Purchase completed for \(offer.plan.rawValue)\(offer.isWelcomeBack ? " (welcome back)" : "")",
                category: .purchases
            )
            return .purchased
        case .pending:
            MidgarLog.info("Purchase pending external approval", category: .purchases)
            return .pending
        case .cancelled:
            MidgarLog.info("Purchase cancelled by user", category: .purchases)
            return .cancelled
        }
    }

    enum RestoreOutcome {
        case restored
        case nothingToRestore
        case cancelled
        case failed
    }

    /// Syncs with the App Store, reports what the account owns to the ledger and
    /// re-reads it. A purchase found on the device counts as restored even when
    /// the sync itself failed.
    func restore() async -> RestoreOutcome {
        guard let store else { return .failed }
        var failure: MidgarStoreError?
        do {
            try await store.restore()
        } catch let error as MidgarStoreError {
            failure = error
            MidgarLog.error("Restore failed: \(error)", category: .purchases)
        } catch {
            failure = .storeKit(String(describing: error))
            MidgarLog.error("Restore failed: \(error)", category: .purchases)
        }
        apply(await store.entitlements)
        let outcome: RestoreOutcome
        if state.isPurchased {
            outcome = .restored
        } else if let failure {
            outcome = PurchaseFailure.isCancellation(failure) ? .cancelled : .failed
        } else {
            outcome = .nothingToRestore
        }
        MidgarLog.info("Restore finished: \(outcome)", category: .purchases)
        return outcome
    }

    func markRunwayPromptShown() {
        runwayPromptShownCached = true
        guard !trialClockIsOverridden else {
            MidgarLog.info("Runway prompt stamp skipped under --trial-day", category: .purchases)
            return
        }
        TrialClock.stampIfAbsent(Date(), for: .runwayPromptShown)
    }

    func loadProof() async -> PaywallProof {
        await Self.readProof(playsAreScrobbled: LastFMService.shared.isAuthenticated)
    }

    @concurrent
    nonisolated private static func readProof(playsAreScrobbled: Bool) async -> PaywallProof {
        let db = DatabaseManager.shared
        do {
            let totals = try db.libraryTotals()
            return PaywallProof(
                trackCount: totals.tracks,
                losslessTrackCount: totals.lossless,
                totalDurationSeconds: totals.seconds,
                plays: try db.scrobbleCount(submittedOnly: playsAreScrobbled),
                playsAreScrobbled: playsAreScrobbled,
                lyricsMatched: try db.lyricsMatchedCount(),
                coversResolved: try db.coversResolvedCount(),
                aiReviewedTracks: try db.aiReviewedTrackCount()
            )
        } catch {
            MidgarLog.error("Paywall proof counts failed: \(error.localizedDescription)", category: .purchases)
            return .empty
        }
    }

    /// An Ask to Buy approval, an offer code, a renewal, a refund or a purchase
    /// on another device arrives here, after the store has already handled it.
    private func listenForStoreEvents() {
        guard storeEventsTask == nil, let store else { return }
        storeEventsTask = Task { [weak self] in
            for await event in await store.events() {
                if case .refused(let productID) = event {
                    MidgarLog.error("The store refused an unverified transaction for \(productID)", category: .purchases)
                }
                guard let self else { return }
                self.apply(await store.entitlements)
            }
        }
    }

    private func apply(_ entitlements: [MidgarEntitlement]) {
        readTrialStartIfNeeded()
        if let pro = entitlements.first(where: { $0.name == FlaccyProducts.entitlement }) {
            setState(.purchased(Self.plan(for: pro)))
        } else {
            setState(trialState())
        }
        noteEntitlementsLoaded()
    }

    /// Announced on both names once: surfaces that only observe `stateDidChange`
    /// still re-render after the first load, even when the state did not move.
    private func noteEntitlementsLoaded() {
        guard !hasLoadedEntitlements else { return }
        hasLoadedEntitlements = true
        NotificationCenter.default.post(name: Self.entitlementsDidLoad, object: nil)
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    /// A lifetime unlock never expires; a subscription is the yearly plan,
    /// whatever its product identifier ends up being called. The store already
    /// keeps the longer-lived grant when someone holds both.
    private static func plan(for entitlement: MidgarEntitlement) -> PurchasePlan {
        entitlement.kind == .nonConsumable ? .lifetime : .yearly
    }

    private func trialState() -> EntitlementState {
        guard trialHasStarted else { return .trialNotStarted }
        switch TrialRunway.phase(start: trialStart, now: Date()) {
        case .trial(let daysRemaining): return .trial(daysRemaining: daysRemaining)
        case .expired: return .expired
        }
    }

    private func setState(_ newState: EntitlementState) {
        guard newState != state else { return }
        MidgarLog.info("Entitlement state \(state) -> \(newState)", category: .purchases)
        state = newState
        if newState.isPurchased {
            TrialReminderScheduler.shared.cancelAll()
        }
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    func requestPaywall() {
        MidgarLog.info("Playback gated, requesting paywall", category: .purchases)
        NotificationCenter.default.post(name: Self.paywallRequired, object: nil)
    }
}

/// Persists the trial's add-only dates in the Keychain so they survive
/// reinstalls; stored after-first-unlock and never synced to iCloud. Every
/// account shares one query shape, and `trialStart` keeps the name it has
/// always had, so existing trials are read back unchanged.
private enum TrialClock {

    enum Account: String {
        case trialStart
        case runwayPromptShown
    }

    /// Absent and unreadable are different answers: before first unlock the
    /// Keychain refuses every read, and that must never pass for "no trial yet".
    enum Lookup {
        case found(Date)
        case absent
        case unreadable(OSStatus)
    }

    #if os(macOS)
    private static let service = "com.midgarcorp.flaccy.mac"
    #else
    private static let service = "com.midgarcorp.flaccy.trial"
    #endif

    static func date(for account: Account) -> Date? {
        guard case .found(let date) = lookup(account) else { return nil }
        return date
    }

    static func lookup(_ account: Account) -> Lookup {
        #if DEBUG
        if CommandLine.arguments.contains("--memory-audit") || CommandLine.arguments.contains("--skip-keychain") {
            return .absent
        }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return status == errSecItemNotFound ? .absent : .unreadable(status)
        }
        guard let data = item as? Data,
              let interval = TimeInterval(String(decoding: data, as: UTF8.self))
        else { return .unreadable(status) }
        return .found(Date(timeIntervalSinceReferenceDate: interval))
    }

    static func stampIfAbsent(_ date: Date, for account: Account) {
        let data = Data(String(date.timeIntervalSinceReferenceDate).utf8)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            MidgarLog.error("Failed to store \(account.rawValue) in Keychain (status \(status))", category: .purchases)
        }
    }
}
