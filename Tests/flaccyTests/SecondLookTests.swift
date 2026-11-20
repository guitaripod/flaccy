import FlaccyCore
import FlaccyEngine
import XCTest
@testable import flaccy

/// Walks one install along the whole runway with the trial's dates held in
/// memory and the clock moved by hand: the trial, its lapse, the second look
/// that opens a month later, the play that starts it and everything after.
/// The calendar itself is proven in `TrialRunwayTests`; this pins what
/// `PurchaseManager` does with it, which is where a mistake costs money.
nonisolated final class SecondLookTests: XCTestCase {

    @MainActor private final class Dates: TrialDateStoring {
        var stored: [TrialClock.Account: Date] = [:]
        var refusesSecondLook = false

        func lookup(_ account: TrialClock.Account) -> TrialClock.Lookup {
            if refusesSecondLook, account == .secondLookStart { return .unreadable(errSecInteractionNotAllowed) }
            return stored[account].map(TrialClock.Lookup.found) ?? .absent
        }

        func stampIfAbsent(_ date: Date, for account: TrialClock.Account) {
            guard stored[account] == nil else { return }
            stored[account] = date
        }
    }

    @MainActor private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private static let day = TrialRunway.day
    private static let trialStart = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @MainActor private func harness(daysAfterTrialStart days: Double, loaded: Bool = true) async -> (PurchaseManager, Dates, Clock) {
        let dates = Dates()
        dates.stored[.trialStart] = Self.trialStart
        let clock = Clock(Self.trialStart.addingTimeInterval(days * Self.day))
        let manager = PurchaseManager(store: nil, dates: dates, now: { clock.now })
        if loaded {
            await manager.refresh()
        } else {
            manager.refreshTrialPhase()
        }
        return (manager, dates, clock)
    }

    private var ownTrack: Track {
        Track(
            fileURL: LibraryPaths.root.appendingPathComponent("Aurelia Vance/Glass Harbor/Low Tide.flac", isDirectory: false),
            title: "Low Tide", artist: "Aurelia Vance", albumTitle: "Glass Harbor", albumArtist: nil,
            trackNumber: 1, duration: 200, artwork: nil, dbID: 1,
            codec: "FLAC", bitDepth: 16, sampleRate: 44_100, channels: 2
        )
    }

    @MainActor func testATrialThatEndedLessThanAMonthAgoStaysEndedAndGated() async {
        let (manager, dates, _) = await harness(daysAfterTrialStart: 36.9)

        XCTAssertEqual(manager.state, .expired)
        XCTAssertFalse(manager.allowsPlayback)
        XCTAssertFalse(manager.isSecondLook)

        manager.noteOwnMusicPlaying(ownTrack)

        XCTAssertEqual(manager.state, .expired)
        XCTAssertNil(dates.stored[.secondLookStart])
    }

    @MainActor func testAMonthAfterTheTrialEndedTheSecondLookWaitsAndPlaybackIsOpen() async {
        let (manager, dates, _) = await harness(daysAfterTrialStart: 37)

        XCTAssertEqual(manager.state, .secondLookReady)
        XCTAssertTrue(manager.allowsPlayback)
        XCTAssertFalse(manager.isSecondLook)
        XCTAssertEqual(manager.lapsedOfferState, .notYet)
        XCTAssertFalse(manager.reminderOptInIsDue)
        XCTAssertNil(dates.stored[.secondLookStart])
    }

    @MainActor func testATrackThatOnlyLoadsSpendsNothing() async {
        let (manager, dates, _) = await harness(daysAfterTrialStart: 90)

        manager.noteTrackStarted(ownTrack)

        XCTAssertEqual(manager.state, .secondLookReady)
        XCTAssertNil(dates.stored[.secondLookStart])
        XCTAssertEqual(dates.stored[.trialStart], Self.trialStart)
    }

    @MainActor func testThePlayStartsSevenFreeDaysAndTheWelcomeBackPrice() async {
        let (manager, dates, clock) = await harness(daysAfterTrialStart: 90)
        let started = expectation(forNotification: PurchaseManager.secondLookDidStart, object: nil)

        manager.noteOwnMusicPlaying(ownTrack)

        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(dates.stored[.secondLookStart], clock.now)
        XCTAssertEqual(dates.stored[.trialStart], Self.trialStart)
        XCTAssertEqual(manager.state, .trial(daysRemaining: 7))
        XCTAssertTrue(manager.isSecondLook)
        XCTAssertEqual(manager.trialStart, clock.now)
        XCTAssertEqual(manager.lapsedOfferState, .available(endsAt: clock.now.addingTimeInterval(15 * Self.day)))
        XCTAssertFalse(manager.reminderOptInIsDue)
    }

    @MainActor func testTheSecondLookRunsOutLikeTheTrialAndNeverComesBack() async {
        let (manager, dates, clock) = await harness(daysAfterTrialStart: 90)
        manager.noteOwnMusicPlaying(ownTrack)
        let began = clock.now

        clock.now = began.addingTimeInterval(6 * Self.day + 23 * 3_600)
        manager.refreshTrialPhase()
        XCTAssertEqual(manager.state, .trial(daysRemaining: 1))

        clock.now = began.addingTimeInterval(7 * Self.day)
        manager.refreshTrialPhase()
        XCTAssertEqual(manager.state, .expired)
        XCTAssertFalse(manager.allowsPlayback)
        XCTAssertEqual(manager.lapsedOfferState, .available(endsAt: began.addingTimeInterval(15 * Self.day)))

        clock.now = began.addingTimeInterval(15 * Self.day)
        manager.refreshTrialPhase()
        XCTAssertEqual(manager.lapsedOfferState, .ended)

        clock.now = began.addingTimeInterval(400 * Self.day)
        manager.refreshTrialPhase()
        manager.noteOwnMusicPlaying(ownTrack)
        XCTAssertEqual(manager.state, .expired)
        XCTAssertEqual(dates.stored[.secondLookStart], began)
    }

    @MainActor func testARelaunchPicksTheSecondLookUpWhereItWas() async {
        let (first, dates, clock) = await harness(daysAfterTrialStart: 90)
        first.noteOwnMusicPlaying(ownTrack)
        let began = clock.now

        clock.now = began.addingTimeInterval(3 * Self.day)
        let relaunched = PurchaseManager(store: nil, dates: dates, now: { clock.now })
        await relaunched.refresh()

        XCTAssertEqual(relaunched.state, .trial(daysRemaining: 4))
        XCTAssertTrue(relaunched.isSecondLook)
        XCTAssertEqual(relaunched.lapsedOfferState, .available(endsAt: began.addingTimeInterval(15 * Self.day)))
    }

    @MainActor func testAPlayBeforeTheEntitlementsAnswerWaitsForThem() async {
        let (manager, dates, clock) = await harness(daysAfterTrialStart: 90, loaded: false)
        XCTAssertEqual(manager.state, .secondLookReady)

        manager.noteOwnMusicPlaying(ownTrack)
        XCTAssertNil(dates.stored[.secondLookStart])
        XCTAssertEqual(manager.state, .secondLookReady)

        await manager.refresh()
        XCTAssertEqual(dates.stored[.secondLookStart], clock.now)
        XCTAssertEqual(manager.state, .trial(daysRemaining: 7))
    }

    @MainActor func testASecondLookDateTheKeychainRefusesIsNeverReadAsNotSpent() async {
        let dates = Dates()
        dates.stored[.trialStart] = Self.trialStart
        dates.stored[.secondLookStart] = Self.trialStart.addingTimeInterval(40 * Self.day)
        dates.refusesSecondLook = true
        let clock = Clock(Self.trialStart.addingTimeInterval(400 * Self.day))
        let manager = PurchaseManager(store: nil, dates: dates, now: { clock.now })
        await manager.refresh()

        XCTAssertEqual(manager.state, .trialNotStarted)
        XCTAssertFalse(manager.isSecondLook)

        dates.refusesSecondLook = false
        manager.refreshTrialPhase()

        XCTAssertEqual(manager.state, .expired)
        XCTAssertTrue(manager.isSecondLook)
    }

    @MainActor func testTheFirstTrialIsUntouchedByAllOfThis() async {
        let (manager, dates, clock) = await harness(daysAfterTrialStart: 2)
        XCTAssertEqual(manager.state, .trial(daysRemaining: 5))
        XCTAssertFalse(manager.isSecondLook)
        XCTAssertEqual(manager.lapsedOfferState, .notYet)

        manager.noteOwnMusicPlaying(ownTrack)
        XCTAssertNil(dates.stored[.secondLookStart])

        clock.now = Self.trialStart.addingTimeInterval(9 * Self.day)
        manager.refreshTrialPhase()
        XCTAssertEqual(manager.state, .expired)
        XCTAssertEqual(manager.lapsedOfferState, .available(endsAt: Self.trialStart.addingTimeInterval(15 * Self.day)))
    }

    @MainActor func testTheWordsForAWaitingSecondLookAreOneSentenceEverywhere() {
        XCTAssertEqual(PaywallCopy.statusLine(for: .secondLookReady), PaywallCopy.secondLookLine)
        XCTAssertEqual(PaywallCopy.settingsSentence(state: .secondLookReady, lifetime: nil), PaywallCopy.secondLookLine)
        XCTAssertEqual(PaywallCopy.waitingLine(for: .secondLookReady), PaywallCopy.secondLookLine)
        XCTAssertEqual(PaywallCopy.waitingLine(for: .trialNotStarted), PaywallCopy.trialStartsLine)
        XCTAssertNil(PaywallCopy.waitingLine(for: .expired))
        XCTAssertNotNil(PaywallCopy.pillLine(state: .secondLookReady, lifetime: nil))
        XCTAssertEqual(PaywallCopy.secondLookHighlights.count, 4)
    }
}
