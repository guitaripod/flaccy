import FlaccyCore
import UserNotifications
import XCTest
@testable import flaccy

/// The request builder is the only place the reminder copy, the paywall
/// routing and the fire times meet, and none of it errors when it drifts: a
/// wrong identifier silently survives `cancelAll`, a missing destination lands
/// the tap on the Library, a mis-built trigger fires at midnight. These pin the
/// pure builder; the calendar itself is proven in `TrialRunwayTests`.
final class TrialReminderSchedulerTests: XCTestCase {

    private let calendar = Calendar.current
    private var start: Date!
    private var reminders: [TrialRunway.Reminder]!
    private var welcomeBackEnds: Date!

    override func setUp() {
        super.setUp()
        start = Date().addingTimeInterval(-2 * TrialRunway.day)
        reminders = TrialRunway.reminders(start: start, now: Date(), calendar: calendar, includeWelcomeBack: true)
        welcomeBackEnds = TrialRunway.lapsedOfferEnd(start: start)
        XCTAssertEqual(reminders.map(\.kind), TrialRunway.Reminder.Kind.allCases)
    }

    private func requests() -> [UNNotificationRequest] {
        TrialReminderScheduler.requests(for: reminders, welcomeBackEnds: welcomeBackEnds)
    }

    private func request(_ kind: TrialRunway.Reminder.Kind) throws -> UNNotificationRequest {
        try XCTUnwrap(requests().first { $0.identifier == kind.rawValue })
    }

    func testIdentifiersAreTheReminderKinds() {
        XCTAssertEqual(requests().map(\.identifier), TrialRunway.Reminder.Kind.allCases.map(\.rawValue))
        XCTAssertEqual(requests().map(\.identifier), ["trial.twoDaysLeft", "trial.ended", "trial.welcomeBack"])
    }

    func testEveryRequestRoutesToThePaywall() {
        for request in requests() {
            XCTAssertEqual(
                request.content.userInfo[TrialReminderScheduler.destinationUserInfoKey] as? String,
                TrialReminderScheduler.paywallDestination,
                request.identifier
            )
            XCTAssertEqual(request.content.userInfo["trial.destination"] as? String, "paywall", request.identifier)
        }
    }

    func testTwoDaysLeftCopy() throws {
        let content = try request(.twoDaysLeft).content
        XCTAssertEqual(content.title, String(localized: "2 days left in your Flaccy trial"))
        XCTAssertEqual(content.body, String(localized: "Open Flaccy to keep everything you've set up."))
    }

    func testEndedCopy() throws {
        let content = try request(.ended).content
        XCTAssertEqual(content.title, String(localized: "Your Flaccy trial has ended"))
        XCTAssertEqual(content.body, String(localized: "Everything you set up is still here."))
    }

    func testWelcomeBackCopyNamesTheWindowEndAndNoPrice() throws {
        let content = try request(.welcomeBack).content
        let ends = welcomeBackEnds.formatted(.dateTime.day().month())
        XCTAssertEqual(content.title, String(localized: "Welcome back to Flaccy"))
        XCTAssertEqual(
            content.body,
            String(localized: "A welcome-back price on Lifetime is available until \(ends).")
        )
        XCTAssertTrue(content.body.contains(ends))
        XCTAssertFalse(content.body.contains("$"))
    }

    func testEveryRequestCarriesTheDefaultSound() {
        for request in requests() {
            XCTAssertEqual(request.content.sound, .default, request.identifier)
        }
    }

    func testTriggersMatchTheReminderFireTimes() throws {
        for reminder in reminders {
            let trigger = try XCTUnwrap(request(reminder.kind).trigger as? UNCalendarNotificationTrigger)
            XCTAssertFalse(trigger.repeats)
            let expected = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireAt)
            for component in [Calendar.Component.year, .month, .day, .hour, .minute, .second] {
                XCTAssertEqual(
                    trigger.dateComponents.value(for: component),
                    expected.value(for: component),
                    "\(reminder.kind.rawValue) \(component)"
                )
            }
            let next = try XCTUnwrap(trigger.nextTriggerDate(), reminder.kind.rawValue)
            XCTAssertEqual(
                next.timeIntervalSinceReferenceDate,
                reminder.fireAt.timeIntervalSinceReferenceDate.rounded(.down),
                accuracy: 0.5,
                reminder.kind.rawValue
            )
        }
    }

    func testTriggersLandInsideTheDeliveryWindow() throws {
        for reminder in reminders {
            let trigger = try XCTUnwrap(request(reminder.kind).trigger as? UNCalendarNotificationTrigger)
            let hour = try XCTUnwrap(trigger.dateComponents.hour)
            XCTAssertTrue((TrialRunway.deliveryWindowStartHour..<TrialRunway.deliveryWindowEndHour).contains(hour))
        }
    }

    func testBuilderIsPure() {
        XCTAssertTrue(TrialReminderScheduler.requests(for: [], welcomeBackEnds: welcomeBackEnds).isEmpty)
        let subset = reminders.filter { $0.kind != .welcomeBack }
        XCTAssertEqual(
            TrialReminderScheduler.requests(for: subset, welcomeBackEnds: welcomeBackEnds).map(\.identifier),
            [TrialRunway.Reminder.Kind.twoDaysLeft.rawValue, TrialRunway.Reminder.Kind.ended.rawValue]
        )
    }
}
