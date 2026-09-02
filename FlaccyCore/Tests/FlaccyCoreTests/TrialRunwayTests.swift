import XCTest
@testable import FlaccyCore

final class TrialRunwayTests: XCTestCase {

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day = TrialRunway.day
    private let hour: TimeInterval = 3_600

    private func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
        in calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private var fixedOffset: Calendar { calendar(in: TimeZone(secondsFromGMT: 7_200)!) }
    private var helsinki: Calendar { calendar(in: TimeZone(identifier: "Europe/Helsinki")!) }
    private var utc: Calendar { calendar(in: TimeZone(secondsFromGMT: 0)!) }

    func testPhaseTable() {
        let table: [(elapsed: TimeInterval, phase: TrialRunway.Phase)] = [
            (0, .trial(daysRemaining: 7)),
            (0.99 * day, .trial(daysRemaining: 7)),
            (1 * day, .trial(daysRemaining: 6)),
            (5 * day, .trial(daysRemaining: 2)),
            (6 * day, .trial(daysRemaining: 1)),
            (6 * day + 23 * hour, .trial(daysRemaining: 1)),
            (7 * day, .expired(daysSinceExpiry: 0)),
            (7 * day + 23 * hour, .expired(daysSinceExpiry: 0)),
            (8 * day, .expired(daysSinceExpiry: 1)),
            (30 * day, .expired(daysSinceExpiry: 23)),
        ]
        for row in table {
            XCTAssertEqual(
                TrialRunway.phase(start: start, now: start.addingTimeInterval(row.elapsed)),
                row.phase,
                "elapsed \(row.elapsed / day) d"
            )
        }
    }

    func testClockWoundBackReadsAsDayOne() {
        XCTAssertEqual(
            TrialRunway.phase(start: start, now: start.addingTimeInterval(-3 * day)),
            .trial(daysRemaining: 7)
        )
        XCTAssertEqual(
            TrialRunway.phase(start: start, now: start.addingTimeInterval(-1)),
            .trial(daysRemaining: 7)
        )
    }

    func testExactTimes() {
        XCTAssertEqual(TrialRunway.exactTime(of: .twoDaysLeft, start: start), start.addingTimeInterval(5 * day))
        XCTAssertEqual(TrialRunway.exactTime(of: .ended, start: start), start.addingTimeInterval(7 * day))
        XCTAssertEqual(TrialRunway.exactTime(of: .welcomeBack, start: start), start.addingTimeInterval(8 * day))
        XCTAssertEqual(
            TrialRunway.exactTime(of: .welcomeBack, start: start),
            TrialRunway.lapsedOfferStart(start: start)
        )
    }

    func testReminderKindsAreTheNotificationIdentifiers() {
        XCTAssertEqual(TrialRunway.Reminder.Kind.twoDaysLeft.rawValue, "trial.twoDaysLeft")
        XCTAssertEqual(TrialRunway.Reminder.Kind.ended.rawValue, "trial.ended")
        XCTAssertEqual(TrialRunway.Reminder.Kind.welcomeBack.rawValue, "trial.welcomeBack")
        XCTAssertEqual(TrialRunway.Reminder.Kind.allCases, [.twoDaysLeft, .ended, .welcomeBack])
    }

    func testDeliveryTimeClampsIntoTheWindow() {
        let calendar = fixedOffset
        let cases: [(input: Date, expected: Date)] = [
            (date(2026, 9, 1, 3, 0, in: calendar), date(2026, 9, 1, 10, 0, in: calendar)),
            (date(2026, 9, 1, 9, 59, in: calendar), date(2026, 9, 1, 10, 0, in: calendar)),
            (date(2026, 9, 1, 10, 0, in: calendar), date(2026, 9, 1, 10, 0, in: calendar)),
            (date(2026, 9, 1, 20, 59, in: calendar), date(2026, 9, 1, 20, 59, in: calendar)),
            (date(2026, 9, 1, 21, 0, in: calendar), date(2026, 9, 2, 10, 0, in: calendar)),
            (date(2026, 9, 1, 21, 30, in: calendar), date(2026, 9, 2, 10, 0, in: calendar)),
            (date(2026, 9, 30, 23, 45, in: calendar), date(2026, 10, 1, 10, 0, in: calendar)),
        ]
        for row in cases {
            let delivered = TrialRunway.deliveryTime(for: row.input, calendar: calendar)
            XCTAssertEqual(delivered, row.expected, "input \(row.input)")
            XCTAssertGreaterThanOrEqual(delivered, row.input, "delivery moved earlier for \(row.input)")
        }
    }

    func testDeliveryTimeKeepsSecondsInsideTheWindow() {
        let calendar = fixedOffset
        let inside = date(2026, 9, 1, 14, 7, in: calendar).addingTimeInterval(23)
        XCTAssertEqual(TrialRunway.deliveryTime(for: inside, calendar: calendar), inside)
    }

    /// The five-day span from the 26th crosses Europe/Helsinki's 2026-03-29 DST
    /// change. start + 5 × 86 400 s lands at 21:30 EEST, one hour later on the
    /// wall clock than the start's 20:30 EET, so the clamp must push it to
    /// 10:00 local on April 1 (07:00 UTC). A fixed +2 offset would have left it
    /// at 20:30, inside the window, and delivered at the wrong hour.
    func testDeliveryTimeIsTenLocalAcrossHelsinkiDaylightSavingChange() {
        let calendar = helsinki
        let start = date(2026, 3, 26, 20, 30, in: calendar)
        let exact = TrialRunway.exactTime(of: .twoDaysLeft, start: start)

        let exactComponents = calendar.dateComponents([.month, .day, .hour, .minute], from: exact)
        XCTAssertEqual(exactComponents.month, 3)
        XCTAssertEqual(exactComponents.day, 31)
        XCTAssertEqual(exactComponents.hour, 21)
        XCTAssertEqual(exactComponents.minute, 30)

        let delivered = TrialRunway.deliveryTime(for: exact, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: delivered)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)
        XCTAssertEqual(delivered, date(2026, 4, 1, 7, 0, in: utc))

        let reminders = TrialRunway.reminders(start: start, now: start, calendar: calendar, includeWelcomeBack: true)
        XCTAssertEqual(reminders.first?.kind, .twoDaysLeft)
        XCTAssertEqual(reminders.first?.fireAt, delivered)
    }

    func testRemindersCarryAllThreeAtTheStartInOrder() {
        let calendar = fixedOffset
        let start = date(2026, 9, 1, 12, 0, in: calendar)
        let reminders = TrialRunway.reminders(start: start, now: start, calendar: calendar, includeWelcomeBack: true)

        XCTAssertEqual(reminders.map(\.kind), [.twoDaysLeft, .ended, .welcomeBack])
        XCTAssertEqual(reminders.map(\.fireAt), [
            date(2026, 9, 6, 12, 0, in: calendar),
            date(2026, 9, 8, 12, 0, in: calendar),
            date(2026, 9, 9, 12, 0, in: calendar),
        ])
    }

    func testRemindersAreClamped() {
        let calendar = fixedOffset
        let start = date(2026, 9, 1, 22, 15, in: calendar)
        let reminders = TrialRunway.reminders(start: start, now: start, calendar: calendar, includeWelcomeBack: true)

        XCTAssertEqual(reminders.map(\.fireAt), [
            date(2026, 9, 7, 10, 0, in: calendar),
            date(2026, 9, 9, 10, 0, in: calendar),
            date(2026, 9, 10, 10, 0, in: calendar),
        ])
    }

    func testRemindersDropPastOnes() {
        let calendar = fixedOffset
        let start = date(2026, 9, 1, 12, 0, in: calendar)
        let now = start.addingTimeInterval(6 * day)
        let reminders = TrialRunway.reminders(start: start, now: now, calendar: calendar, includeWelcomeBack: true)

        XCTAssertEqual(reminders.map(\.kind), [.ended, .welcomeBack])
    }

    func testRemindersDropOneFiringExactlyNow() {
        let calendar = fixedOffset
        let start = date(2026, 9, 1, 12, 0, in: calendar)
        let reminders = TrialRunway.reminders(
            start: start, now: start.addingTimeInterval(5 * day), calendar: calendar, includeWelcomeBack: true
        )

        XCTAssertEqual(reminders.map(\.kind), [.ended, .welcomeBack])
    }

    func testRemindersKeepOneWhoseExactTimeHasPassedButWhoseDeliveryHasNot() {
        let calendar = fixedOffset
        let start = date(2026, 9, 1, 3, 0, in: calendar)
        let now = date(2026, 9, 6, 5, 0, in: calendar)
        let reminders = TrialRunway.reminders(start: start, now: now, calendar: calendar, includeWelcomeBack: true)

        XCTAssertEqual(reminders.first?.kind, .twoDaysLeft)
        XCTAssertEqual(reminders.first?.fireAt, date(2026, 9, 6, 10, 0, in: calendar))
    }

    func testRemindersDropWelcomeBackWhenExcluded() {
        let calendar = fixedOffset
        let start = date(2026, 9, 1, 12, 0, in: calendar)
        let reminders = TrialRunway.reminders(start: start, now: start, calendar: calendar, includeWelcomeBack: false)

        XCTAssertEqual(reminders.map(\.kind), [.twoDaysLeft, .ended])
    }

    func testRemindersAreEmptyOnceEverythingHasFired() {
        let calendar = fixedOffset
        let start = date(2026, 9, 1, 12, 0, in: calendar)
        let reminders = TrialRunway.reminders(
            start: start, now: start.addingTimeInterval(9 * day), calendar: calendar, includeWelcomeBack: true
        )

        XCTAssertTrue(reminders.isEmpty)
    }

    func testRunwayBannerGate() {
        XCTAssertTrue(TrialRunway.runwayBannerIsDue(phase: .trial(daysRemaining: 1), alreadyShown: false))
        XCTAssertTrue(TrialRunway.runwayBannerIsDue(phase: .trial(daysRemaining: 0), alreadyShown: false))
        XCTAssertFalse(TrialRunway.runwayBannerIsDue(phase: .trial(daysRemaining: 1), alreadyShown: true))
        XCTAssertFalse(TrialRunway.runwayBannerIsDue(phase: .trial(daysRemaining: 2), alreadyShown: false))
        XCTAssertFalse(TrialRunway.runwayBannerIsDue(phase: .trial(daysRemaining: 7), alreadyShown: false))
        XCTAssertFalse(TrialRunway.runwayBannerIsDue(phase: .expired(daysSinceExpiry: 0), alreadyShown: false))
        XCTAssertFalse(TrialRunway.runwayBannerIsDue(phase: .expired(daysSinceExpiry: 3), alreadyShown: true))
    }

    func testRunwayBannerIsDueOnDaySixOfTheTrial() {
        let phase = TrialRunway.phase(start: start, now: start.addingTimeInterval(6 * day + 2 * hour))
        XCTAssertTrue(TrialRunway.runwayBannerIsDue(phase: phase, alreadyShown: false))
        let dayFive = TrialRunway.phase(start: start, now: start.addingTimeInterval(5 * day + 23 * hour))
        XCTAssertFalse(TrialRunway.runwayBannerIsDue(phase: dayFive, alreadyShown: false))
    }

    func testLapsedOfferWindowBounds() {
        XCTAssertEqual(TrialRunway.lapsedOfferStart(start: start), start.addingTimeInterval(8 * day))
        XCTAssertEqual(TrialRunway.lapsedOfferEnd(start: start), start.addingTimeInterval(15 * day))
    }

    func testLapsedOfferIsNotYetBeforeTheWindowOpens() {
        XCTAssertEqual(TrialRunway.lapsedOffer(start: start, now: start), .notYet)
        XCTAssertEqual(TrialRunway.lapsedOffer(start: start, now: start.addingTimeInterval(7 * day)), .notYet)
        XCTAssertEqual(
            TrialRunway.lapsedOffer(start: start, now: start.addingTimeInterval(8 * day - 1)),
            .notYet
        )
    }

    func testLapsedOfferIsAvailableInsideTheWindow() {
        let end = start.addingTimeInterval(15 * day)
        XCTAssertEqual(
            TrialRunway.lapsedOffer(start: start, now: start.addingTimeInterval(8 * day)),
            .available(endsAt: end)
        )
        XCTAssertEqual(
            TrialRunway.lapsedOffer(start: start, now: start.addingTimeInterval(11 * day)),
            .available(endsAt: end)
        )
        XCTAssertEqual(
            TrialRunway.lapsedOffer(start: start, now: start.addingTimeInterval(15 * day - 1)),
            .available(endsAt: end)
        )
    }

    func testLapsedOfferEndsAtTheCloseAndStaysEndedForever() {
        XCTAssertEqual(TrialRunway.lapsedOffer(start: start, now: start.addingTimeInterval(15 * day)), .ended)
        XCTAssertEqual(TrialRunway.lapsedOffer(start: start, now: start.addingTimeInterval(16 * day)), .ended)
        XCTAssertEqual(TrialRunway.lapsedOffer(start: start, now: start.addingTimeInterval(400 * day)), .ended)
        XCTAssertEqual(TrialRunway.lapsedOffer(start: start, now: start.addingTimeInterval(10 * 365 * day)), .ended)
    }

    func testLapsedOfferOpensTheDayAfterExpiryAndTheWindowIsSevenDays() {
        let opening = TrialRunway.lapsedOfferStart(start: start)
        XCTAssertEqual(TrialRunway.phase(start: start, now: opening), .expired(daysSinceExpiry: 1))
        XCTAssertEqual(
            TrialRunway.lapsedOfferEnd(start: start).timeIntervalSince(opening),
            TimeInterval(TrialRunway.lapsedOfferWindowDays) * day
        )
    }

    func testConsentWindowTable() {
        let table: [(phase: TrialRunway.Phase, open: Bool)] = [
            (.trial(daysRemaining: 7), false),
            (.trial(daysRemaining: 6), true),
            (.trial(daysRemaining: 5), true),
            (.trial(daysRemaining: 4), true),
            (.trial(daysRemaining: 3), true),
            (.trial(daysRemaining: 2), false),
            (.trial(daysRemaining: 1), false),
            (.trial(daysRemaining: 0), false),
            (.expired(daysSinceExpiry: 0), false),
            (.expired(daysSinceExpiry: 5), false),
        ]
        for row in table {
            XCTAssertEqual(TrialRunway.consentWindowIsOpen(phase: row.phase), row.open, "\(row.phase)")
        }
    }

    func testConsentWindowTracksTheCalendar() {
        for elapsedDays in 0..<10 {
            let phase = TrialRunway.phase(start: start, now: start.addingTimeInterval(TimeInterval(elapsedDays) * day))
            XCTAssertEqual(TrialRunway.consentWindowIsOpen(phase: phase), (1...4).contains(elapsedDays), "day \(elapsedDays + 1)")
        }
    }
}
