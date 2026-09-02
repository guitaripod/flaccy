import FlaccyCore
import Foundation
import RevenueCat

/// Every sentence the paywall, the Settings entitlement row, the day-6 runway
/// and the reminder consent alert put on screen, written once for both Apple
/// clients so iOS and the Mac cannot drift a word — or a rounding — apart.
enum PaywallCopy {

    static func proofTitle(for state: EntitlementState) -> String {
        state == .expired
            ? String(localized: "Everything you set up stays")
            : String(localized: "What you've set up so far")
    }

    static func proofLine(_ line: PaywallProof.Line) -> String {
        switch line {
        case .lossless(let tracks, let hours):
            return losslessLine(tracks: tracks, hours: hours)
        case .scrobbled(let plays):
            return plays == 1
                ? String(localized: "1 play scrobbled to Last.fm")
                : String(localized: "\(number(plays)) plays scrobbled to Last.fm")
        case .playsCounted(let plays):
            return plays == 1
                ? String(localized: "1 play counted")
                : String(localized: "\(number(plays)) plays counted")
        case .lyrics(let songs):
            return songs == 1
                ? String(localized: "1 song with synced lyrics")
                : String(localized: "\(number(songs)) songs with synced lyrics")
        case .covers(let covers):
            return covers == 1
                ? String(localized: "1 album cover found")
                : String(localized: "\(number(covers)) album covers found")
        case .aiReviewed(let tracks):
            return tracks == 1
                ? String(localized: "1 track reviewed by AI")
                : String(localized: "\(number(tracks)) tracks reviewed by AI")
        }
    }

    private static func losslessLine(tracks: Int, hours: Int) -> String {
        let tracksText = tracks == 1
            ? String(localized: "1 lossless track")
            : String(localized: "\(number(tracks)) lossless tracks")
        guard hours > 0 else { return tracksText }
        let hoursText = hours == 1
            ? String(localized: "1 hour of music")
            : String(localized: "\(number(hours)) hours of music")
        return "\(tracksText) · \(hoursText)"
    }

    private static func number(_ value: Int) -> String {
        LibraryLoadPhaseCopy.number(value)
    }

    static func lifetimeBadge(for offer: PurchaseOffer?) -> String {
        offer?.isWelcomeBack == true
            ? String(localized: "WELCOME BACK")
            : String(localized: "PAY ONCE")
    }

    /// The welcome-back window names its end date and, only when honest, the
    /// usual price; otherwise Lifetime is priced against Yearly when both are
    /// quoted in the same currency. A family-shareable product says so last.
    static func lifetimeCaption(lifetime: PurchaseOffer?, yearly: PurchaseOffer?, welcomeBackEnds: Date?) -> String {
        var lines: [String] = []
        if let lifetime, lifetime.isWelcomeBack, let welcomeBackEnds {
            lines.append(String(localized: "Welcome-back price, available until \(welcomeBackEnds.formatted(.dateTime.day().month()))."))
            if let regular = lifetime.regularPrice {
                lines.append(String(localized: "Usually \(regular)."))
            }
        } else if let years = yearsOfYearly(lifetime: lifetime, yearly: yearly) {
            lines.append(String(localized: "Pay once, use it for life. Less than \(years) years of Yearly."))
        } else {
            lines.append(String(localized: "Pay once, use it for life. Nothing renews."))
        }
        if lifetime?.storeProduct.isFamilyShareable == true {
            lines.append(String(localized: "Shareable with your family"))
        }
        return lines.joined(separator: "\n")
    }

    private static func yearsOfYearly(lifetime: PurchaseOffer?, yearly: PurchaseOffer?) -> Int? {
        guard let lifetime, let yearly,
              let currency = lifetime.storeProduct.currencyCode,
              currency == yearly.storeProduct.currencyCode
        else { return nil }
        return PaywallPricing.yearsOfYearly(lifetime: lifetime.storeProduct.price, yearly: yearly.storeProduct.price)
    }

    static var yearlyCaption: String {
        String(localized: "Renews yearly. Cancel anytime.")
    }

    static func yearlyFootnote(yearly: PurchaseOffer) -> String {
        String(localized: "Yearly renews automatically at \(yearly.displayPrice)/year until cancelled. Manage or cancel in your Apple Account settings.")
    }

    static func purchaseTitle(plan: PurchasePlan, offer: PurchaseOffer?) -> String {
        switch plan {
        case .yearly:
            return offer.map { String(localized: "Start Yearly · \($0.displayPrice)") } ?? String(localized: "Start Yearly")
        case .lifetime:
            return offer.map { String(localized: "Get Lifetime · \($0.displayPrice)") } ?? String(localized: "Get Lifetime")
        }
    }

    static func purchaseSubline(plan: PurchasePlan) -> String {
        switch plan {
        case .yearly: return String(localized: "Renews yearly. Cancel anytime.")
        case .lifetime: return String(localized: "One-time purchase. No subscription.")
        }
    }

    static func purchaseHint(plan: PurchasePlan) -> String {
        switch plan {
        case .yearly: return String(localized: "Subscribes for a year, renewing automatically until cancelled")
        case .lifetime: return String(localized: "Buys lifetime access with a one-time purchase")
        }
    }

    /// `.trial(daysRemaining: 1)` covers the whole last day, so the line never
    /// promises "tomorrow" — it says what is true for all twenty-four hours.
    static func statusLine(for state: EntitlementState) -> String {
        switch state {
        case .trial(let daysRemaining) where daysRemaining <= TrialRunway.runwayBannerAtDaysRemaining:
            return lastDayLine
        case .trial(let daysRemaining):
            return String(localized: "\(daysRemaining) days left in your trial")
        case .expired:
            return String(localized: "Your trial has ended. Everything you set up is still here.")
        case .purchased(.lifetime):
            return String(localized: "Lifetime unlocked. Thank you.")
        case .purchased(.yearly):
            return String(localized: "Flaccy Pro is active. Thank you.")
        }
    }

    static var lastDayLine: String {
        String(localized: "Less than a day left in your trial")
    }

    static var runwayToast: String {
        String(localized: "Less than a day left in your trial — Lifetime is one payment, no subscription.")
    }

    /// The Settings entitlement sentence while there is still something to
    /// buy: the trial counts down toward one payment, an ended trial names the
    /// price, and the welcome-back window quotes its offer against the usual
    /// price only when that is honest. Nil once purchased — each client has
    /// its own thank-you there.
    static func settingsSentence(state: EntitlementState, lifetime: PurchaseOffer?) -> String? {
        switch state {
        case .purchased:
            return nil
        case .trial(let daysRemaining):
            guard let price = lifetime?.displayPrice else {
                return String(localized: "\(daysRemaining) days left in your free trial")
            }
            return String(localized: "\(daysRemaining) days left · \(price), one payment")
        case .expired:
            guard let lifetime else { return String(localized: "Your free trial has ended") }
            guard lifetime.isWelcomeBack else {
                return String(localized: "Your trial ended · Lifetime is \(lifetime.displayPrice), one payment")
            }
            guard let regular = lifetime.regularPrice else {
                return String(localized: "Your trial ended · Welcome-back price \(lifetime.displayPrice)")
            }
            return String(localized: "Your trial ended · Welcome-back price \(lifetime.displayPrice), usually \(regular)")
        }
    }

    /// The titlebar pill's short form of the same state; nil once purchased.
    static func pillLine(state: EntitlementState, lifetime: PurchaseOffer?) -> String? {
        switch state {
        case .purchased:
            return nil
        case .trial(let daysRemaining) where daysRemaining <= TrialRunway.runwayBannerAtDaysRemaining:
            return String(localized: "Under a day left · Get Lifetime")
        case .trial(let daysRemaining):
            return String(localized: "Trial · \(daysRemaining) days left")
        case .expired:
            if let lifetime, lifetime.isWelcomeBack {
                return String(localized: "Welcome back · Lifetime \(lifetime.displayPrice)")
            }
            return String(localized: "Trial ended · Get Lifetime")
        }
    }

    static var reminderConsentTitle: String {
        String(localized: "Reminders before your trial ends?")
    }

    static var reminderConsentBody: String {
        String(localized: "Flaccy can send three notifications: two days before your trial ends, on the last day, and once if a welcome-back price on Lifetime becomes available. Nothing else. You can turn them off any time in Settings.")
    }

    static var remindMe: String {
        String(localized: "Remind Me")
    }

    static var noThanks: String {
        String(localized: "No Thanks")
    }

    static var notificationsOffHint: String {
        String(localized: "Turn on notifications for Flaccy in Settings")
    }
}
