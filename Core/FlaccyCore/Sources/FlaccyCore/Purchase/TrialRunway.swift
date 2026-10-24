import Foundation

/// The trial's calendar, derived entirely from its start date: which day it is,
/// when each reminder fires, when the day-6 banner is due and when the
/// welcome-back window opens and closes. Every client reads this and nothing
/// else, so a wound-back clock, a reinstall or a tapped notification all agree.
public enum TrialRunway {
    public static let lengthDays = 7
    public static let twoDaysLeftReminderDay = 5
    public static let runwayBannerAtDaysRemaining = 1
    public static let lapsedOfferDelayDays = 1
    public static let lapsedOfferWindowDays = 7
    public static let deliveryWindowStartHour = 10
    public static let deliveryWindowEndHour = 21
    public static let day: TimeInterval = 86_400

    public enum Phase: Equatable, Sendable {
        case trial(daysRemaining: Int)
        case expired(daysSinceExpiry: Int)
    }

    /// elapsed = max(0, floor((now − start) / day)); trial while elapsed < lengthDays.
    /// A clock wound back before the start therefore reads as day one, never as
    /// a negative day or a phantom expiry.
    public static func phase(start: Date, now: Date) -> Phase {
        let elapsed = max(0, Int(floor(now.timeIntervalSince(start) / day)))
        if elapsed < lengthDays { return .trial(daysRemaining: lengthDays - elapsed) }
        return .expired(daysSinceExpiry: elapsed - lengthDays)
    }

    public struct Reminder: Equatable, Sendable {
        public enum Kind: String, CaseIterable, Sendable {
            case twoDaysLeft = "trial.twoDaysLeft"
            case ended = "trial.ended"
            case welcomeBack = "trial.welcomeBack"
        }
        public let kind: Kind
        public let fireAt: Date

        public init(kind: Kind, fireAt: Date) {
            self.kind = kind
            self.fireAt = fireAt
        }
    }

    /// The unclamped instant each reminder belongs to: start + 5 d, + 7 d, + 8 d.
    public static func exactTime(of kind: Reminder.Kind, start: Date) -> Date {
        switch kind {
        case .twoDaysLeft: return start.addingTimeInterval(TimeInterval(twoDaysLeftReminderDay) * day)
        case .ended: return start.addingTimeInterval(TimeInterval(lengthDays) * day)
        case .welcomeBack: return lapsedOfferStart(start: start)
        }
    }

    /// Moves a fire time into the 10:00 ≤ t < 21:00 local window, and only ever
    /// later: before 10:00 becomes 10:00 the same calendar day, 21:00 or later
    /// becomes 10:00 the next calendar day, anything inside the window is
    /// returned untouched. The calendar's own time zone decides the hour, which
    /// is what keeps a reminder at 10:00 across a DST change.
    public static func deliveryTime(for date: Date, calendar: Calendar) -> Date {
        let hour = calendar.component(.hour, from: date)
        if (deliveryWindowStartHour..<deliveryWindowEndHour).contains(hour) { return date }
        let dayOffset = hour < deliveryWindowStartHour ? 0 : 1
        guard let targetDay = calendar.date(byAdding: .day, value: dayOffset, to: date),
              let opening = calendar.date(
                bySettingHour: deliveryWindowStartHour, minute: 0, second: 0, of: targetDay
              )
        else { return date }
        return opening
    }

    /// Future reminders only (fireAt > now), each clamped. `includeWelcomeBack` false drops R3.
    public static func reminders(
        start: Date,
        now: Date,
        calendar: Calendar,
        includeWelcomeBack: Bool
    ) -> [Reminder] {
        Reminder.Kind.allCases
            .filter { includeWelcomeBack || $0 != .welcomeBack }
            .map { Reminder(kind: $0, fireAt: deliveryTime(for: exactTime(of: $0, start: start), calendar: calendar)) }
            .filter { $0.fireAt > now }
    }

    public static func runwayBannerIsDue(phase: Phase, alreadyShown: Bool) -> Bool {
        guard case .trial(let daysRemaining) = phase else { return false }
        return daysRemaining <= runwayBannerAtDaysRemaining && !alreadyShown
    }

    /// Both trial reminders must still lie ahead when consent is asked for, so
    /// the window is day two through day five of the trial — at least one day
    /// elapsed, at least three remaining — and it never reopens.
    public static func consentWindowIsOpen(phase: Phase) -> Bool {
        guard case .trial(let daysRemaining) = phase else { return false }
        let elapsedDays = lengthDays - daysRemaining
        return elapsedDays >= 1 && daysRemaining >= 3
    }

    public enum LapsedOffer: Equatable, Sendable {
        case notYet
        case available(endsAt: Date)
        case ended
    }

    public static func lapsedOfferStart(start: Date) -> Date {
        start.addingTimeInterval(TimeInterval(lengthDays + lapsedOfferDelayDays) * day)
    }

    public static func lapsedOfferEnd(start: Date) -> Date {
        lapsedOfferStart(start: start).addingTimeInterval(TimeInterval(lapsedOfferWindowDays) * day)
    }

    /// `.notYet` before the window opens, `.available` until it closes, and
    /// `.ended` from the close onwards, forever: the window is fixed by the
    /// trial start, so nothing a later launch does can reopen it.
    public static func lapsedOffer(start: Date, now: Date) -> LapsedOffer {
        if now < lapsedOfferStart(start: start) { return .notYet }
        let end = lapsedOfferEnd(start: start)
        if now < end { return .available(endsAt: end) }
        return .ended
    }
}
