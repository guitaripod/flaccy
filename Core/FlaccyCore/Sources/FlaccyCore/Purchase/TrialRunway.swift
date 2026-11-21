import Foundation

/// The trial's calendar, derived entirely from its start date: which day it is,
/// when each reminder fires, when the day-6 banner is due, when the
/// welcome-back window opens and closes and when a second look opens. Every
/// client reads this and nothing else, so a wound-back clock, a reinstall or a
/// tapped notification all agree.
public enum TrialRunway {
    public static let lengthDays = 7
    public static let secondLookAfterExpiryDays = 30
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
            case secondLook = "trial.secondLook"
        }
        public let kind: Kind
        public let fireAt: Date

        public init(kind: Kind, fireAt: Date) {
            self.kind = kind
            self.fireAt = fireAt
        }
    }

    /// The unclamped instant each reminder belongs to: start + 5 d, + 7 d, + 8 d
    /// and, for the second look, + 37 d. That reminder keeps the month's wait
    /// whatever opened the look early: a look opened by Flaccy 2 opened in
    /// front of the person, who needs no notification to hear of it.
    public static func exactTime(of kind: Reminder.Kind, start: Date) -> Date {
        switch kind {
        case .twoDaysLeft: return start.addingTimeInterval(TimeInterval(twoDaysLeftReminderDay) * day)
        case .ended: return start.addingTimeInterval(TimeInterval(lengthDays) * day)
        case .welcomeBack: return lapsedOfferStart(start: start)
        case .secondLook: return secondLookOpens(trialStart: start, editionTwoOpened: nil)
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

    /// Future reminders only (fireAt > now), each clamped. `includeWelcomeBack`
    /// false drops R3, `includeSecondLook` false drops R4.
    public static func reminders(
        start: Date,
        now: Date,
        calendar: Calendar,
        includeWelcomeBack: Bool,
        includeSecondLook: Bool
    ) -> [Reminder] {
        Reminder.Kind.allCases
            .filter { includeWelcomeBack || $0 != .welcomeBack }
            .filter { includeSecondLook || $0 != .secondLook }
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
    /// `.ended` from the close onwards: the window is fixed by the trial start,
    /// so no later launch reopens it. Only a second look brings the price back.
    public static func lapsedOffer(start: Date, now: Date) -> LapsedOffer {
        if now < lapsedOfferStart(start: start) { return .notYet }
        let end = lapsedOfferEnd(start: start)
        if now < end { return .available(endsAt: end) }
        return .ended
    }

    /// Where a person stands with the one second look they ever get: seven
    /// more free days for someone whose trial ran out a month or more ago, or
    /// had already run out when Flaccy 2 first opened on the device.
    public enum SecondLook: Equatable, Sendable {
        /// The trial is still running, or ended less than thirty days ago on a
        /// device that already had Flaccy 2.
        case notYet
        /// The free days are waiting and start at the next play of the person's own music.
        case ready
        /// It started on this date, which the runway now counts from.
        case started(Date)
    }

    /// The instant a second look opens: thirty days after the trial ran out,
    /// or the moment Flaccy 2 first opened on the device (`editionTwoOpened`,
    /// nil while that is not known) for a trial that had already run out by
    /// then. Everyone who left before 2.0 is therefore welcomed back with free
    /// days the day they return, while a trial that runs out on Flaccy 2 still
    /// waits its month, so no trial is ever simply fourteen days long.
    public static func secondLookOpens(trialStart: Date, editionTwoOpened: Date?) -> Date {
        let ranOut = trialStart.addingTimeInterval(TimeInterval(lengthDays) * day)
        let afterTheWait = ranOut.addingTimeInterval(TimeInterval(secondLookAfterExpiryDays) * day)
        guard let editionTwoOpened, ranOut <= editionTwoOpened else { return afterTheWait }
        return min(afterTheWait, editionTwoOpened)
    }

    /// A stored start always wins, so a second look that has begun can never
    /// be offered again, whatever the clock says.
    public static func secondLook(
        trialStart: Date,
        secondLookStart: Date?,
        editionTwoOpened: Date?,
        now: Date
    ) -> SecondLook {
        if let secondLookStart { return .started(secondLookStart) }
        return now >= secondLookOpens(trialStart: trialStart, editionTwoOpened: editionTwoOpened) ? .ready : .notYet
    }

    /// The date every day of the runway counts from: the second look's start
    /// once it has one, the trial's until then.
    public static func runwayStart(trialStart: Date, secondLookStart: Date?) -> Date {
        secondLookStart ?? trialStart
    }

    /// A second look carries the welcome-back price from its first day, through
    /// its seven free days and to the close of the window that follows them.
    public static func secondLookOffer(secondLookStart: Date, now: Date) -> LapsedOffer {
        let end = lapsedOfferEnd(start: secondLookStart)
        return now < end ? .available(endsAt: end) : .ended
    }
}
