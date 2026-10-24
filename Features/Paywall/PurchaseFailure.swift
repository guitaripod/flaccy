import Foundation
import MidgarCommerce

/// A purchase that did not go through, in words the paywall can show. MidgarStore wraps StoreKit's own error in its
/// description, so the network, storefront and cancellation cases are read from it.
nonisolated enum PurchaseFailure: LocalizedError, Equatable {
    case unreachable
    case notAvailableInStorefront
    case unverified
    case other

    init(_ error: MidgarStoreError) {
        switch error {
        case .unverifiedTransaction:
            self = .unverified
        case .unknownProduct:
            self = .notAvailableInStorefront
        case .storeKit(let description) where description.contains("notAvailableInStorefront"):
            self = .notAvailableInStorefront
        case .storeKit(let description) where description.contains("networkError"):
            self = .unreachable
        case .storeKit, .readOnly, .unsupportedPlatform:
            self = .other
        }
    }

    /// A dismissed App Store sheet or sign-in prompt is the person's decision, not a failure to report.
    static func isCancellation(_ error: MidgarStoreError) -> Bool {
        guard case .storeKit(let description) = error else { return false }
        return description.contains("userCancelled")
    }

    var errorDescription: String? {
        switch self {
        case .unreachable:
            String(localized: "Can't reach the App Store. Check your connection and try again.")
        case .notAvailableInStorefront:
            String(localized: "This plan isn't available in your country or region.")
        case .unverified:
            String(localized: "The App Store couldn't verify this purchase. Try again, or choose Restore Purchases.")
        case .other:
            String(localized: "The purchase didn't go through. Try again in a moment.")
        }
    }
}
