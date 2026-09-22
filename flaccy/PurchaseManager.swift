import Foundation
import RevenueCat
import Security

nonisolated enum PurchasePlan: String, Equatable, Hashable, Sendable {
    case yearly
    case lifetime
}

nonisolated enum EntitlementState: Equatable, Hashable {
    case trial(daysRemaining: Int)
    case expired
    case purchased(PurchasePlan)

    var isPurchased: Bool {
        if case .purchased = self { return true }
        return false
    }
}

/// One buyable plan as the paywall renders it: the store's localized price plus
/// the RevenueCat package that purchases it. A welcome-back offer is the same
/// plan sold through the `lapsed` offering, and carries the regular price only
/// when that comparison is honest — same currency, and actually lower.
struct PurchaseOffer: Equatable {
    let plan: PurchasePlan
    let displayPrice: String
    let package: Package
    var isWelcomeBack = false
    var regularPrice: String? = nil

    var storeProduct: StoreProduct { package.storeProduct }

    static func == (lhs: PurchaseOffer, rhs: PurchaseOffer) -> Bool {
        lhs.plan == rhs.plan
            && lhs.isWelcomeBack == rhs.isWelcomeBack
            && lhs.package.storeProduct.productIdentifier == rhs.package.storeProduct.productIdentifier
    }
}

/// Entitlement source of truth for the Apple clients, backed by RevenueCat.
///
/// RevenueCat owns receipts, restores, renewals and cross-device state; the
/// seven-day trial stays local because it starts before any purchase exists and
/// must survive a reinstall, which the Keychain gives us for free. The `pro`
/// entitlement is attached to both the yearly subscription and the lifetime
/// unlock, so one boolean answers "may this person play music". Everything the
/// runway needs — which day it is, whether the banner is due, whether the
/// welcome-back window is open — derives from the one stored start date through
/// `TrialRunway`, so the clients never do their own arithmetic.
final class PurchaseManager {

    static let shared = PurchaseManager()

    static let stateDidChange = Notification.Name("PurchaseStateDidChange")
    static let paywallRequired = Notification.Name("PaywallRequired")
    static let customerInfoDidLoad = Notification.Name("PurchaseCustomerInfoDidLoad")

    static let entitlementID = "pro"
    static let lapsedOfferingID = "lapsed"
    static let trialLengthDays = TrialRunway.lengthDays

    private(set) var state: EntitlementState = .trial(daysRemaining: trialLengthDays)
    private(set) var offers: [PurchaseOffer] = []
    private(set) var trialStart = Date()
    private(set) var trialStartIsSettled = false
    private(set) var hasReceivedCustomerInfo = false
    private var lapsedOfferingSeenThisSession = false
    private var lapsedPackage: Package?
    private var runwayPromptShownCached = false

    private var customerInfoTask: Task<Void, Never>?

    private static let lapsedOfferingSeenKey = "flaccy.lapsedOfferingSeen"

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

    /// The `lapsed` offering, once seen by any offerings fetch, is remembered
    /// across launches so an offline consent or foreground still schedules the
    /// welcome-back reminder.
    var lapsedOfferingExists: Bool {
        lapsedOfferingSeenThisSession || UserDefaults.standard.bool(forKey: Self.lapsedOfferingSeenKey)
    }

    /// The welcome-back lifetime plan, built at read time so "Usually <regular>"
    /// reflects the regular price whenever it has loaded, not whenever the lapsed
    /// package happened to arrive.
    var lapsedLifetimeOffer: PurchaseOffer? {
        guard let package = lapsedPackage else { return nil }
        return PurchaseOffer(
            plan: .lifetime,
            displayPrice: package.storeProduct.localizedPriceString,
            package: package,
            isWelcomeBack: true,
            regularPrice: Self.regularPrice(against: lifetimeOffer?.storeProduct, welcome: package.storeProduct)
        )
    }

    private init() {}

    var allowsPlayback: Bool {
        state != .expired
    }

    var yearlyOffer: PurchaseOffer? { offers.first { $0.plan == .yearly } }
    var lifetimeOffer: PurchaseOffer? { offers.first { $0.plan == .lifetime } }

    var runwayPhase: TrialRunway.Phase {
        TrialRunway.phase(start: trialStart, now: Date())
    }

    var lapsedOfferState: TrialRunway.LapsedOffer {
        guard hasReceivedCustomerInfo, state == .expired else { return .notYet }
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
        guard hasReceivedCustomerInfo, case .trial = state else { return false }
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
        guard hasReceivedCustomerInfo, case .trial = state,
              !TrialReminderScheduler.shared.hasBeenAsked
        else { return false }
        return TrialRunway.consentWindowIsOpen(phase: runwayPhase)
    }

    func start() {
        settleTrialStartIfNeeded()
        #if DEBUG
        applyTrialDayOverride()
        #endif
        setState(trialState(from: trialStart))
        configureRevenueCat()
        publishFunnelEntitlement()
        listenForCustomerInfo()
        Task {
            await refresh()
            await TrialReminderScheduler.shared.refresh()
        }
        Task { await migrateStoreKitPurchasesIfNeeded() }
    }

    /// Reads the stored start date until it has actually been read back. A
    /// launch before first unlock fails both the read and the add-only stamp
    /// (errSecInteractionNotAllowed), leaving `trialStart` at "now" — so the
    /// read is retried at every later chance and the state re-derived from it.
    private func settleTrialStartIfNeeded() {
        guard !trialStartIsSettled else { return }
        trialStart = TrialClock.ensureStartDate()
        trialStartIsSettled = TrialClock.date(for: .trialStart) != nil
        if trialStartIsSettled {
            publishFunnelEntitlement()
        } else {
            AppLogger.warning("Trial start not readable from the Keychain yet; will retry", category: .purchases)
        }
    }

    private func publishFunnelEntitlement() {
        PurchaseFunnel.noteEntitlement(state, trialStart: trialStart, trialStartIsSettled: trialStartIsSettled)
    }

    /// Called by both paywalls once their offers have loaded, so the price
    /// recorded is the one the person was actually shown.
    func notePaywallShown() {
        PurchaseFunnel.notePaywallShown(offer: lifetimeOfferToPresent, state: state)
    }

    /// Re-derives the trial day from the stored start, for a process that has
    /// lived across midnight; a purchase is never touched.
    func refreshTrialPhase() {
        guard !state.isPurchased else { return }
        settleTrialStartIfNeeded()
        setState(trialState(from: trialStart))
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
        trialStartIsSettled = true
        trialDayOverrideActive = true
        AppLogger.info("Trial clock overridden: day \(day) (elapsed \(day - 1) d)", category: .purchases)
    }
    #endif

    private static let migratedKey = "flaccy.revenuecat.migratedStoreKit"

    /// Lifetime unlocks bought before RevenueCat existed live only in StoreKit's
    /// transaction history; one sync on the first RevenueCat launch hands them
    /// over so nobody who already paid is asked again.
    private func migrateStoreKitPurchasesIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.migratedKey) else { return }
        do {
            let info = try await Purchases.shared.syncPurchases()
            apply(info)
            defaults.set(true, forKey: Self.migratedKey)
            AppLogger.info("Synced StoreKit history into RevenueCat (pro active: \(state.isPurchased))", category: .purchases)
        } catch {
            AppLogger.error("StoreKit → RevenueCat sync failed: \(error.localizedDescription)", category: .purchases)
        }
    }

    private func configureRevenueCat() {
        guard !Purchases.isConfigured else { return }
        Purchases.logLevel = .warn
        Purchases.configure(
            with: .builder(withAPIKey: Secrets.revenueCatAPIKey)
                .with(storeKitVersion: .storeKit2)
                .build()
        )
        AppLogger.info("RevenueCat configured", category: .purchases)
    }

    func refresh() async {
        do {
            let info = try await Purchases.shared.customerInfo()
            apply(info)
        } catch {
            AppLogger.error("Customer info fetch failed: \(error.localizedDescription)", category: .purchases)
            refreshTrialPhase()
            noteCustomerInfoLoaded()
        }
        await loadLapsedOfferIfNeeded()
    }

    @discardableResult
    func loadOffersIfNeeded() async -> [PurchaseOffer] {
        if !offers.isEmpty { return offers }
        do {
            let offerings = try await Purchases.shared.offerings()
            noteLapsedOffering(in: offerings)
            guard let current = offerings.current else {
                AppLogger.warning("No current RevenueCat offering", category: .purchases)
                return []
            }
            var loaded: [PurchaseOffer] = []
            if let annual = current.annual {
                loaded.append(PurchaseOffer(plan: .yearly, displayPrice: annual.storeProduct.localizedPriceString, package: annual))
            }
            if let lifetime = current.lifetime {
                loaded.append(PurchaseOffer(plan: .lifetime, displayPrice: lifetime.storeProduct.localizedPriceString, package: lifetime))
            }
            offers = loaded
            AppLogger.info(
                "Loaded offers: \(loaded.map { "\($0.plan.rawValue)=\($0.displayPrice)" }.joined(separator: ", ")) (lapsed offering: \(lapsedOfferingExists))",
                category: .purchases
            )
            if !loaded.isEmpty {
                NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
            }
        } catch {
            AppLogger.error("Offerings load failed: \(error.localizedDescription)", category: .purchases)
        }
        return offers
    }

    /// Every offerings fetch records whether the `lapsed` offering exists and
    /// keeps its lifetime package, so the welcome-back price needs no second
    /// round trip when the window opens.
    private func noteLapsedOffering(in offerings: Offerings) {
        let package = offerings.all[Self.lapsedOfferingID]?.lifetime
        if package != nil {
            lapsedOfferingSeenThisSession = true
            UserDefaults.standard.set(true, forKey: Self.lapsedOfferingSeenKey)
        }
        let changed = (lapsedPackage == nil) != (package == nil)
        lapsedPackage = package
        if changed {
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        }
    }

    /// The welcome-back lifetime package is only surfaced while its window is
    /// open for an expired trial (`lifetimeOfferToPresent` gates on that), and
    /// is fetched again only when no offerings fetch has captured it yet.
    func loadLapsedOfferIfNeeded() async {
        await loadOffersIfNeeded()
        refreshTrialPhase()
        guard case .available = lapsedOfferState, lapsedPackage == nil else { return }
        do {
            let offerings = try await Purchases.shared.offerings()
            noteLapsedOffering(in: offerings)
            guard let offer = lapsedLifetimeOffer else {
                AppLogger.info("Welcome-back window open but no lapsed offering is configured", category: .purchases)
                return
            }
            AppLogger.info(
                "Loaded welcome-back offer: \(offer.displayPrice) (usually \(offer.regularPrice ?? "unknown"))",
                category: .purchases
            )
        } catch {
            AppLogger.error("Lapsed offering load failed: \(error.localizedDescription)", category: .purchases)
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
        return regular.localizedPriceString
    }

    enum PurchaseOutcome {
        case purchased
        case pending
        case cancelled
    }

    func purchase(_ offer: PurchaseOffer) async throws -> PurchaseOutcome {
        PurchaseFunnel.noteCheckoutStarted(offer)
        do {
            let outcome = try await performPurchase(offer)
            PurchaseFunnel.noteCheckoutFinished(Self.funnelOutcome(outcome))
            return outcome
        } catch {
            PurchaseFunnel.noteCheckoutFinished(.failed)
            throw error
        }
    }

    private func performPurchase(_ offer: PurchaseOffer) async throws -> PurchaseOutcome {
        do {
            let result = try await Purchases.shared.purchase(package: offer.package)
            if result.userCancelled {
                AppLogger.info("Purchase cancelled by user", category: .purchases)
                return .cancelled
            }
            apply(result.customerInfo)
            AppLogger.info(
                "Purchase completed for \(offer.plan.rawValue)\(offer.isWelcomeBack ? " (welcome back)" : "")",
                category: .purchases
            )
            return .purchased
        } catch let error as ErrorCode where error == .paymentPendingError {
            AppLogger.info("Purchase pending external approval", category: .purchases)
            return .pending
        } catch let error as ErrorCode where error == .purchaseCancelledError {
            AppLogger.info("Purchase cancelled by user", category: .purchases)
            return .cancelled
        }
    }

    private static func funnelOutcome(_ outcome: PurchaseOutcome) -> PurchaseFunnel.CheckoutOutcome {
        switch outcome {
        case .purchased: .purchased
        case .pending: .pending
        case .cancelled: .cancelled
        }
    }

    enum RestoreOutcome {
        case restored
        case nothingToRestore
        case failed
    }

    func restore() async -> RestoreOutcome {
        do {
            let info = try await Purchases.shared.restorePurchases()
            apply(info)
        } catch {
            AppLogger.error("Restore failed: \(error.localizedDescription)", category: .purchases)
            return .failed
        }
        let outcome: RestoreOutcome = state.isPurchased ? .restored : .nothingToRestore
        AppLogger.info("Restore finished: \(outcome)", category: .purchases)
        return outcome
    }

    func markRunwayPromptShown() {
        runwayPromptShownCached = true
        guard !trialClockIsOverridden else {
            AppLogger.info("Runway prompt stamp skipped under --trial-day", category: .purchases)
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
            AppLogger.error("Paywall proof counts failed: \(error.localizedDescription)", category: .purchases)
            return .empty
        }
    }

    private func listenForCustomerInfo() {
        guard customerInfoTask == nil else { return }
        customerInfoTask = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                guard let self else { return }
                await MainActor.run { self.apply(info) }
            }
        }
    }

    private func apply(_ info: CustomerInfo) {
        settleTrialStartIfNeeded()
        if let entitlement = info.entitlements[Self.entitlementID], entitlement.isActive {
            setState(.purchased(Self.plan(for: entitlement)))
        } else {
            setState(trialState(from: trialStart))
        }
        noteCustomerInfoLoaded()
    }

    /// Announced on both names once: surfaces that only observe `stateDidChange`
    /// still re-render after the first load, even when the state did not move.
    private func noteCustomerInfoLoaded() {
        guard !hasReceivedCustomerInfo else { return }
        hasReceivedCustomerInfo = true
        NotificationCenter.default.post(name: Self.customerInfoDidLoad, object: nil)
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    /// A lifetime unlock never expires; anything with an expiration date is the
    /// subscription, whatever its product identifier ends up being called.
    private static func plan(for entitlement: EntitlementInfo) -> PurchasePlan {
        entitlement.expirationDate == nil ? .lifetime : .yearly
    }

    private func trialState(from start: Date) -> EntitlementState {
        switch TrialRunway.phase(start: start, now: Date()) {
        case .trial(let daysRemaining): return .trial(daysRemaining: daysRemaining)
        case .expired: return .expired
        }
    }

    private func setState(_ newState: EntitlementState) {
        guard newState != state else { return }
        AppLogger.info("Entitlement state \(state) -> \(newState)", category: .purchases)
        state = newState
        publishFunnelEntitlement()
        if newState.isPurchased {
            TrialReminderScheduler.shared.cancelAll()
        }
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    func requestPaywall() {
        AppLogger.info("Playback gated, requesting paywall", category: .purchases)
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

    #if os(macOS)
    private static let service = "com.midgarcorp.flaccy.mac"
    #else
    private static let service = "com.midgarcorp.flaccy.trial"
    #endif

    static func ensureStartDate() -> Date {
        if let existing = date(for: .trialStart) {
            return existing
        }
        let now = Date()
        stampIfAbsent(now, for: .trialStart)
        AppLogger.info("Trial started, stamped start date in Keychain", category: .purchases)
        return now
    }

    static func date(for account: Account) -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let interval = TimeInterval(String(decoding: data, as: UTF8.self))
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: interval)
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
            AppLogger.error("Failed to store \(account.rawValue) in Keychain (status \(status))", category: .purchases)
        }
    }
}
