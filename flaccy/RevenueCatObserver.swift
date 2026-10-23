import Foundation
import MidgarCore
import RevenueCat

/// Keeps RevenueCat in the loop as an observer, for its dashboard and the funnel attributes `PurchaseFunnel` writes.
///
/// RevenueCat runs with `purchasesAreCompletedBy: .myApp` over StoreKit 2. `MidgarStore` buys, verifies, finishes and
/// reports every transaction to the ledger, `PurchaseManager` gates on that, and this type only tells RevenueCat what
/// already happened. Nothing here can grant, withhold or delay a purchase: every call returns at once, and a slow or
/// failing RevenueCat is logged and dropped. A test host or a screenshot seed leaves it unconfigured.
enum RevenueCatObserver {
    private static let historySyncedKey = "flaccy.revenuecat.migratedStoreKit"
    private static var syncTask: Task<Void, Never>?

    /// Configures the SDK and, once per install, hands it the StoreKit history from before RevenueCat (lifetime
    /// unlocks bought in the first versions), so those owners stay customers in its dashboard. Safe on every launch.
    static func start() {
        guard configureIfNeeded() else { return }
        guard !UserDefaults.standard.bool(forKey: historySyncedKey) else { return }
        enqueueSync(reason: "history")
    }

    static func reportPurchase(_ productID: String) {
        guard configureIfNeeded() else { return }
        enqueueSync(reason: "purchase \(productID)")
    }

    static func reportRestore() {
        guard configureIfNeeded() else { return }
        enqueueSync(reason: "restore")
    }

    @discardableResult
    private static func configureIfNeeded() -> Bool {
        if Purchases.isConfigured { return true }
        guard FlaccyMidgar.reachesMidgarServices else { return false }
        Purchases.logLevel = .warn
        Purchases.configure(
            with: .builder(withAPIKey: Secrets.revenueCatAPIKey)
                .with(purchasesAreCompletedBy: .myApp, storeKitVersion: .storeKit2)
                .build()
        )
        MidgarLog.info("RevenueCat configured in observer mode", category: .purchases)
        return true
    }

    /// Runs syncs one after another: a purchase landing while the launch sync is still in flight must not race it,
    /// and neither may hold up the caller.
    private static func enqueueSync(reason: String) {
        let previous = syncTask
        syncTask = Task {
            await previous?.value
            await sync(reason: reason)
        }
    }

    private static func sync(reason: String) async {
        do {
            let info = try await Purchases.shared.syncPurchases()
            UserDefaults.standard.set(true, forKey: historySyncedKey)
            let active = info.entitlements.active.keys.sorted().joined(separator: ",")
            MidgarLog.info("RevenueCat sync ok (\(reason)) active=[\(active)]", category: .purchases)
        } catch {
            MidgarLog.notice("RevenueCat sync failed (\(reason)): \(error.localizedDescription)", category: .purchases)
        }
    }
}
