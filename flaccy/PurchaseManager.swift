import Foundation
import Security
import StoreKit

nonisolated enum EntitlementState: Equatable, Hashable {
    case trial(daysRemaining: Int)
    case expired
    case purchased
}

final class PurchaseManager {

    static let shared = PurchaseManager()

    static let stateDidChange = Notification.Name("PurchaseStateDidChange")
    static let paywallRequired = Notification.Name("PaywallRequired")

    static let lifetimeProductID = "com.midgarcorp.flaccy.lifetime"
    static let trialLengthDays = 7

    private(set) var state: EntitlementState = .trial(daysRemaining: trialLengthDays)
    private(set) var product: Product?

    private var updatesTask: Task<Void, Never>?

    private init() {}

    var allowsPlayback: Bool {
        state != .expired
    }

    func start() {
        let trialStart = TrialClock.ensureStartDate()
        setState(trialState(from: trialStart))
        listenForTransactionUpdates()
        Task {
            await refresh()
            await loadProductIfNeeded()
        }
    }

    func refresh() async {
        if await hasLifetimeEntitlement() {
            setState(.purchased)
        } else {
            setState(trialState(from: TrialClock.ensureStartDate()))
        }
    }

    @discardableResult
    func loadProductIfNeeded() async -> Product? {
        if let product { return product }
        do {
            product = try await Product.products(for: [Self.lifetimeProductID]).first
            if let product {
                AppLogger.info("Loaded product \(product.id) at \(product.displayPrice)", category: .purchases)
            } else {
                AppLogger.warning("Product \(Self.lifetimeProductID) not found in store response", category: .purchases)
            }
        } catch {
            AppLogger.error("Product load failed: \(error.localizedDescription)", category: .purchases)
        }
        return product
    }

    enum PurchaseOutcome {
        case purchased
        case pending
        case cancelled
    }

    func purchase() async throws -> PurchaseOutcome {
        guard let product = await loadProductIfNeeded() else {
            throw StoreKitError.notAvailableInStorefront
        }
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try verified(verification)
            await transaction.finish()
            setState(.purchased)
            AppLogger.info("Lifetime purchase completed (transaction \(transaction.id))", category: .purchases)
            return .purchased
        case .pending:
            AppLogger.info("Purchase pending external approval", category: .purchases)
            return .pending
        case .userCancelled:
            AppLogger.info("Purchase cancelled by user", category: .purchases)
            return .cancelled
        @unknown default:
            AppLogger.warning("Purchase returned unknown result", category: .purchases)
            return .cancelled
        }
    }

    @discardableResult
    func restore() async -> Bool {
        do {
            try await AppStore.sync()
        } catch {
            AppLogger.error("AppStore.sync failed during restore: \(error.localizedDescription)", category: .purchases)
        }
        await refresh()
        let restored = state == .purchased
        AppLogger.info("Restore finished, purchased: \(restored)", category: .purchases)
        return restored
    }

    private func listenForTransactionUpdates() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try self.verified(update)
                    await transaction.finish()
                    AppLogger.info("Transaction update for \(transaction.productID), revoked: \(transaction.revocationDate != nil)", category: .purchases)
                    await self.refresh()
                } catch {
                    AppLogger.error("Unverified transaction update: \(error.localizedDescription)", category: .purchases)
                }
            }
        }
    }

    private func hasLifetimeEntitlement() async -> Bool {
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            if transaction.productID == Self.lifetimeProductID, transaction.revocationDate == nil {
                return true
            }
        }
        return false
    }

    private func verified(_ result: VerificationResult<Transaction>) throws -> Transaction {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified(_, let error):
            throw error
        }
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

    private static let service = "com.midgarcorp.flaccy.trial"
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
