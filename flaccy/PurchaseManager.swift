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
/// the RevenueCat package that purchases it.
struct PurchaseOffer: Equatable {
    let plan: PurchasePlan
    let displayPrice: String
    let package: Package

    static func == (lhs: PurchaseOffer, rhs: PurchaseOffer) -> Bool {
        lhs.plan == rhs.plan && lhs.package.identifier == rhs.package.identifier
    }
}

/// Entitlement source of truth for the Apple clients, backed by RevenueCat.
///
/// RevenueCat owns receipts, restores, renewals and cross-device state; the
/// seven-day trial stays local because it starts before any purchase exists and
/// must survive a reinstall, which the Keychain gives us for free. The `pro`
/// entitlement is attached to both the yearly subscription and the lifetime
/// unlock, so one boolean answers "may this person play music".
final class PurchaseManager {

    static let shared = PurchaseManager()

    static let stateDidChange = Notification.Name("PurchaseStateDidChange")
    static let paywallRequired = Notification.Name("PaywallRequired")

    static let entitlementID = "pro"
    static let trialLengthDays = 7

    private(set) var state: EntitlementState = .trial(daysRemaining: trialLengthDays)
    private(set) var offers: [PurchaseOffer] = []

    private var customerInfoTask: Task<Void, Never>?

    private init() {}

    var allowsPlayback: Bool {
        state != .expired
    }

    var yearlyOffer: PurchaseOffer? { offers.first { $0.plan == .yearly } }
    var lifetimeOffer: PurchaseOffer? { offers.first { $0.plan == .lifetime } }

    func start() {
        let trialStart = TrialClock.ensureStartDate()
        setState(trialState(from: trialStart))
        configureRevenueCat()
        listenForCustomerInfo()
        Task {
            await migrateStoreKitPurchasesIfNeeded()
            await refresh()
            await loadOffersIfNeeded()
        }
    }

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
            if !state.isPurchased {
                setState(trialState(from: TrialClock.ensureStartDate()))
            }
        }
    }

    @discardableResult
    func loadOffersIfNeeded() async -> [PurchaseOffer] {
        if !offers.isEmpty { return offers }
        do {
            guard let current = try await Purchases.shared.offerings().current else {
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
                "Loaded offers: \(loaded.map { "\($0.plan.rawValue)=\($0.displayPrice)" }.joined(separator: ", "))",
                category: .purchases
            )
        } catch {
            AppLogger.error("Offerings load failed: \(error.localizedDescription)", category: .purchases)
        }
        return offers
    }

    enum PurchaseOutcome {
        case purchased
        case pending
        case cancelled
    }

    func purchase(_ plan: PurchasePlan) async throws -> PurchaseOutcome {
        let offers = await loadOffersIfNeeded()
        guard let offer = offers.first(where: { $0.plan == plan }) else {
            throw ErrorCode.productNotAvailableForPurchaseError
        }
        do {
            let result = try await Purchases.shared.purchase(package: offer.package)
            if result.userCancelled {
                AppLogger.info("Purchase cancelled by user", category: .purchases)
                return .cancelled
            }
            apply(result.customerInfo)
            AppLogger.info("Purchase completed for \(plan.rawValue)", category: .purchases)
            return .purchased
        } catch let error as ErrorCode where error == .paymentPendingError {
            AppLogger.info("Purchase pending external approval", category: .purchases)
            return .pending
        } catch let error as ErrorCode where error == .purchaseCancelledError {
            AppLogger.info("Purchase cancelled by user", category: .purchases)
            return .cancelled
        }
    }

    @discardableResult
    func restore() async -> Bool {
        do {
            let info = try await Purchases.shared.restorePurchases()
            apply(info)
        } catch {
            AppLogger.error("Restore failed: \(error.localizedDescription)", category: .purchases)
        }
        let restored = state.isPurchased
        AppLogger.info("Restore finished, purchased: \(restored)", category: .purchases)
        return restored
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
        if let entitlement = info.entitlements[Self.entitlementID], entitlement.isActive {
            setState(.purchased(Self.plan(for: entitlement)))
        } else {
            setState(trialState(from: TrialClock.ensureStartDate()))
        }
    }

    /// A lifetime unlock never expires; anything with an expiration date is the
    /// subscription, whatever its product identifier ends up being called.
    private static func plan(for entitlement: EntitlementInfo) -> PurchasePlan {
        entitlement.expirationDate == nil ? .lifetime : .yearly
    }

    /// Days elapsed are clamped at zero so winding the device clock behind the
    /// stored start date cannot make the trial appear longer than seven days.
    private func trialState(from start: Date) -> EntitlementState {
        let elapsedDays = max(0, Int(Date().timeIntervalSince(start) / 86_400))
        let remaining = Self.trialLengthDays - elapsedDays
        return remaining > 0 ? .trial(daysRemaining: remaining) : .expired
    }

    private func setState(_ newState: EntitlementState) {
        guard newState != state else { return }
        AppLogger.info("Entitlement state \(state) -> \(newState)", category: .purchases)
        state = newState
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    func requestPaywall() {
        AppLogger.info("Playback gated, requesting paywall", category: .purchases)
        NotificationCenter.default.post(name: Self.paywallRequired, object: nil)
    }
}

/// Persists the trial start date in the Keychain so it survives reinstalls;
/// stored after-first-unlock and never synced to iCloud.
private enum TrialClock {

    #if os(macOS)
    private static let service = "com.midgarcorp.flaccy.mac"
    #else
    private static let service = "com.midgarcorp.flaccy.trial"
    #endif
    private static let account = "trialStart"

    static func ensureStartDate() -> Date {
        if let existing = readStartDate() {
            return existing
        }
        let now = Date()
        storeStartDate(now)
        AppLogger.info("Trial started, stamped start date in Keychain", category: .purchases)
        return now
    }

    private static func readStartDate() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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

    private static func storeStartDate(_ date: Date) {
        let data = Data(String(date.timeIntervalSinceReferenceDate).utf8)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            AppLogger.error("Failed to store trial start in Keychain (status \(status))", category: .purchases)
        }
    }
}
