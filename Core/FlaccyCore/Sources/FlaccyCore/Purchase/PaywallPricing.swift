import Foundation

/// Price arithmetic the paywalls quote, done on the store's decimals and never
/// on the localized strings, so every client rounds the same way.
public enum PaywallPricing {

    /// ceil(lifetime ÷ yearly), the number of yearly renewals a lifetime unlock
    /// costs less than. Nil when there is no yearly price to divide by, and nil
    /// under two because "less than 1 year of Yearly" would read as an argument
    /// against Lifetime.
    public static func yearsOfYearly(lifetime: Decimal, yearly: Decimal) -> Int? {
        guard yearly > 0 else { return nil }
        var ratio = lifetime / yearly
        var rounded = Decimal()
        NSDecimalRound(&rounded, &ratio, 0, .up)
        let years = NSDecimalNumber(decimal: rounded).intValue
        return years >= 2 ? years : nil
    }
}
