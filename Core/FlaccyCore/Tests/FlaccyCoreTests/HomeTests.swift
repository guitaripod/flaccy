import XCTest
@testable import FlaccyCore

final class HomeLayoutTests: XCTestCase {

    func testL1StandardEncodesEverySectionAndNothingHidden() {
        XCTAssertEqual(HomeLayout.standard.encoded, "continue,jumpBackIn,onThisDay,thisWeek,madeForYou,recentlyAdded|")
        XCTAssertTrue(HomeLayout.standard.isStandard)
    }

    func testL2MissingOrBlankTextIsTheStandardLayout() {
        XCTAssertEqual(HomeLayout.decode(nil), .standard)
        XCTAssertEqual(HomeLayout.decode(""), .standard)
        XCTAssertEqual(HomeLayout.decode("  "), .standard)
    }

    func testL3DecodeKeepsTheOrderAndAppendsUnmentionedSections() {
        let layout = HomeLayout.decode("thisWeek,continue|thisWeek")
        XCTAssertEqual(layout.order, [.thisWeek, .resume, .jumpBackIn, .onThisDay, .madeForYou, .recentlyAdded])
        XCTAssertEqual(layout.hidden, [.thisWeek])
        XCTAssertEqual(layout.visible, [.resume, .jumpBackIn, .onThisDay, .madeForYou, .recentlyAdded])
    }

    func testL4UnknownIdentifiersAndDuplicatesAreDropped() {
        let layout = HomeLayout.decode("bogus,madeForYou,madeForYou|bogus,continue")
        XCTAssertEqual(layout.order, [.madeForYou, .resume, .jumpBackIn, .onThisDay, .thisWeek, .recentlyAdded])
        XCTAssertEqual(layout.hidden, [.resume])
    }

    func testL5MovesClampToEitherEnd() {
        XCTAssertEqual(HomeLayout.standard.moving(from: 0, to: 99).order.last, .resume)
        XCTAssertEqual(HomeLayout.standard.moving(from: 5, to: -3).order.first, .recentlyAdded)
        XCTAssertEqual(HomeLayout.standard.moving(from: 9, to: 0), .standard)
    }

    func testL6HidingRoundTripsAndShowingAgainRestoresTheStandard() {
        let hidden = HomeLayout.standard.setting(.onThisDay, visible: false)
        XCTAssertEqual(hidden.encoded, "continue,jumpBackIn,onThisDay,thisWeek,madeForYou,recentlyAdded|onThisDay")
        XCTAssertEqual(HomeLayout.decode(hidden.encoded), hidden)
        XCTAssertEqual(hidden.setting(.onThisDay, visible: true), .standard)
    }
}

final class HomeComposerTests: XCTestCase {

    private func facts(
        tracks: Int = 100,
        history: Bool = true,
        playing: Bool = false,
        resume: Bool = true,
        jump: Int = 6,
        added: Int = 12,
        onThisDay: Bool = true,
        week: Bool = true
    ) -> HomeAvailability {
        HomeAvailability(
            libraryTrackCount: tracks,
            hasListeningHistory: history,
            isPlaying: playing,
            canResume: resume,
            jumpBackInCount: jump,
            recentlyAddedCount: added,
            hasOnThisDay: onThisDay,
            hasWeekPlays: week
        )
    }

    func testC1AnEmptyLibraryHasNoHero() {
        XCTAssertEqual(HomeComposer.hero(for: facts(tracks: 0)), .empty)
        XCTAssertFalse(HomeComposer.shows(.resume, given: facts(tracks: 0)))
        XCTAssertFalse(HomeComposer.shows(.madeForYou, given: facts(tracks: 0)))
    }

    func testC2PlayingOffersTheNextDecision() {
        XCTAssertEqual(HomeComposer.hero(for: facts(playing: true)), .upNext)
        XCTAssertEqual(HomeComposer.hero(for: facts(history: false, playing: true)), .dayOne)
    }

    func testC3APausedResumableSessionLeads() {
        XCTAssertEqual(HomeComposer.hero(for: facts()), .resume)
    }

    func testC4NothingToResumeFallsBackOnHistory() {
        XCTAssertEqual(HomeComposer.hero(for: facts(resume: false)), .upNext)
        XCTAssertEqual(HomeComposer.hero(for: facts(history: false, resume: false)), .dayOne)
    }

    func testC5TheStandardLayoutPairsOnThisDayWithThisWeek() {
        XCTAssertEqual(HomeComposer.blocks(layout: .standard, facts: facts()), [
            .single(.resume), .single(.jumpBackIn), .pair(.onThisDay, .thisWeek),
            .single(.madeForYou), .single(.recentlyAdded),
        ])
    }

    func testC6SectionsWithNothingToShowStayOut() {
        XCTAssertEqual(HomeComposer.blocks(layout: .standard, facts: facts(jump: 1, added: 0, onThisDay: false)), [
            .single(.resume), .single(.thisWeek), .single(.madeForYou),
        ])
    }

    func testC7CompactSectionsPairOnlyWhenNeighbours() {
        let layout = HomeLayout.decode("onThisDay,recentlyAdded,thisWeek,continue,jumpBackIn,madeForYou|")
        XCTAssertEqual(HomeComposer.blocks(layout: layout, facts: facts()), [
            .single(.onThisDay), .single(.recentlyAdded), .single(.thisWeek),
            .single(.resume), .single(.jumpBackIn), .single(.madeForYou),
        ])
        let hiddenBetween = HomeLayout.decode("onThisDay,recentlyAdded,thisWeek|recentlyAdded")
        XCTAssertEqual(HomeComposer.blocks(layout: hiddenBetween, facts: facts()).first, .pair(.onThisDay, .thisWeek))
    }

    func testC8HeroMixFollowsThePreference() {
        XCTAssertEqual(HomeComposer.heroMix(among: ["crate-dig", "heavy-rotation"]), "heavy-rotation")
        XCTAssertEqual(HomeComposer.heroMix(among: ["tonights-spin", "crate-dig"]), "tonights-spin")
        XCTAssertEqual(HomeComposer.heroMix(among: ["something-new"]), "something-new")
        XCTAssertNil(HomeComposer.heroMix(among: []))
    }
}

final class HomeResumeTests: XCTestCase {

    private let now = HomeFixtures.date(2026, 10, 25, 12, 0)

    func testP1AQueueFromOneAlbumNamesTheAlbum() {
        let context = PlaybackContext.derived(from: [
            .init(album: "Field Lines", credit: "Meridian Wolde"),
            .init(album: " field lines ", credit: "MERIDIAN WOLDE"),
        ])
        XCTAssertEqual(context.kind, .album)
        XCTAssertEqual(context.id, "field lines\u{1F}meridian wolde")
        XCTAssertEqual(context.title, "Field Lines")
        XCTAssertEqual(context.subtitle, "Meridian Wolde")
        XCTAssertEqual(context.key, "album:field lines\u{1F}meridian wolde")
    }

    func testP2AnythingElseIsAnAnonymousQueue() {
        XCTAssertEqual(PlaybackContext.derived(from: [
            .init(album: "Field Lines", credit: "Meridian Wolde"),
            .init(album: "Statuary", credit: "Ashgrove"),
        ]), .anonymousQueue)
        XCTAssertEqual(PlaybackContext.derived(from: []), .anonymousQueue)
        XCTAssertEqual(PlaybackContext.derived(from: [.init(album: "  ", credit: "Someone")]), .anonymousQueue)
    }

    func testR1RemainingTimeAndSegments() {
        let point = ResumePoint(trackIndex: 1, elapsed: 120, durations: [200, 300, 100], savedAt: now)
        XCTAssertEqual(point.remainingSeconds, 280, accuracy: 0.0001)
        XCTAssertEqual(point.fractionInTrack, 0.4, accuracy: 0.0001)
        XCTAssertEqual(point.segments(), [1, 0.4, 0])
        XCTAssertEqual(point.trackCount, 3)
    }

    func testR2TheLastSecondsOfTheLastTrackCountAsFinished() {
        XCTAssertTrue(ResumePoint(trackIndex: 2, elapsed: 95, durations: [200, 300, 100], savedAt: now).isFinished)
        XCTAssertFalse(ResumePoint(trackIndex: 2, elapsed: 80, durations: [200, 300, 100], savedAt: now).isFinished)
        XCTAssertFalse(ResumePoint(trackIndex: 2, elapsed: 95, durations: [200, 300, 100], savedAt: now).isResumable(now: now))
    }

    func testR3ASessionOlderThanFourteenDaysIsHistory() {
        let durations: [Double] = [200, 300]
        let edge = ResumePoint(trackIndex: 0, elapsed: 10, durations: durations, savedAt: now.addingTimeInterval(-14 * 86_400))
        let stale = ResumePoint(trackIndex: 0, elapsed: 10, durations: durations, savedAt: now.addingTimeInterval(-15 * 86_400))
        XCTAssertTrue(edge.isResumable(now: now))
        XCTAssertFalse(stale.isResumable(now: now))
    }

    func testR4ALongQueueDrawsOneContinuousSegment() {
        let point = ResumePoint(trackIndex: 10, elapsed: 50, durations: Array(repeating: 100, count: 25), savedAt: now)
        XCTAssertEqual(point.segments().count, 1)
        XCTAssertEqual(point.segments()[0], 0.42, accuracy: 0.0001)
    }

    func testR5AnIndexOutsideTheQueueHasNothingToResume() {
        let point = ResumePoint(trackIndex: 4, elapsed: 0, durations: [100, 100], savedAt: now)
        XCTAssertEqual(point.segments(), [])
        XCTAssertEqual(point.remainingSeconds, 0)
        XCTAssertTrue(point.isFinished)
    }

    func testT1RecencyWords() {
        let cal = HomeFixtures.calendar
        XCTAssertEqual(ResumeRecency.of(now.addingTimeInterval(-600), now: now, calendar: cal), .justNow)
        XCTAssertEqual(ResumeRecency.of(HomeFixtures.date(2026, 10, 25, 8, 0), now: now, calendar: cal), .earlierToday)
        XCTAssertEqual(ResumeRecency.of(HomeFixtures.date(2026, 10, 25, 2, 0), now: now, calendar: cal), .lastNight)
        XCTAssertEqual(ResumeRecency.of(HomeFixtures.date(2026, 10, 24, 23, 40), now: now, calendar: cal), .lastNight)
        XCTAssertEqual(ResumeRecency.of(HomeFixtures.date(2026, 10, 24, 14, 0), now: now, calendar: cal), .yesterday)
        XCTAssertEqual(ResumeRecency.of(HomeFixtures.date(2026, 10, 21, 10, 0), now: now, calendar: cal), .weekday(4))
        let old = HomeFixtures.date(2026, 10, 10, 9, 0)
        XCTAssertEqual(ResumeRecency.of(old, now: now, calendar: cal), .date(old))
        XCTAssertEqual(
            ResumeRecency.of(HomeFixtures.date(2026, 10, 25, 1, 0), now: HomeFixtures.date(2026, 10, 25, 3, 0), calendar: cal),
            .earlierToday
        )
    }
}

final class HomeRecentsTests: XCTestCase {

    private func album(_ name: String) -> PlaybackContext {
        PlaybackContext(kind: .album, id: name, title: name.capitalized, subtitle: "")
    }

    private func at(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + seconds)
    }

    func testRC1RecordingPutsTheContextFirstOnceAndIgnoresPlainQueues() {
        let recents = RecentContexts()
            .recording(album("a"), at: at(1))
            .recording(album("b"), at: at(2))
            .recording(album("a"), at: at(3))
            .recording(.anonymousQueue, at: at(4))
        XCTAssertEqual(recents.entries.map(\.context.id), ["a", "b"])
        XCTAssertEqual(recents.entries.first?.playedAt, at(3))
        XCTAssertEqual(recents.removing(key: "album:a").entries.map(\.context.id), ["b"])
    }

    func testRC2CapacityKeepsTheNewest() {
        var recents = RecentContexts()
        for index in 0..<30 {
            recents = recents.recording(album("x\(index)"), at: at(Double(index)))
        }
        XCTAssertEqual(recents.entries.count, RecentContexts.capacity)
        XCTAssertEqual(recents.entries.first?.context.id, "x29")
        XCTAssertEqual(recents.entries.last?.context.id, "x6")
    }

    func testJ1JumpBackInMergesNewestFirstAndRecordedWinsTies() {
        let recents = [
            RecentContexts.Entry(context: album("a"), playedAt: at(100)),
            RecentContexts.Entry(context: album("b"), playedAt: at(50)),
        ]
        let history = [
            RecentContexts.Entry(context: album("c"), playedAt: at(80)),
            RecentContexts.Entry(context: album("a"), playedAt: at(10)),
            RecentContexts.Entry(context: album("d"), playedAt: at(50)),
        ]
        XCTAssertEqual(
            JumpBackIn.pick(recents: recents, history: history, excluding: []).map(\.id),
            ["a", "c", "b", "d"]
        )
        XCTAssertEqual(
            JumpBackIn.pick(recents: recents, history: history, excluding: ["album:c"]).map(\.id),
            ["a", "b", "d"]
        )
        XCTAssertEqual(
            JumpBackIn.pick(recents: recents, history: history, excluding: [], limit: 2).map(\.id),
            ["a", "c"]
        )
    }
}

final class HomeHistoryTests: XCTestCase {

    private let now = HomeFixtures.date(2026, 10, 25, 12, 0)
    private let cal = HomeFixtures.calendar

    private func plays(_ album: String, _ artist: String, _ date: Date, count: Int, seconds: Int = 200) -> [HomePlay] {
        (0..<count).map { HomePlay(album: album, artist: artist, at: date.addingTimeInterval(Double($0) * 60), seconds: seconds) }
    }

    func testO1TheMostPlayedAlbumOnThisDateInAnEarlierYear() {
        let history = plays("Midnatt", "Solveig", HomeFixtures.date(2023, 10, 25, 9, 0), count: 4)
            + plays("Statuary", "Ashgrove", HomeFixtures.date(2024, 10, 25, 9, 0), count: 3)
            + plays("Other", "Someone", HomeFixtures.date(2025, 10, 25, 9, 0), count: 2)
        let pick = OnThisDay.pick(history, now: now, calendar: cal)
        XCTAssertEqual(pick?.kind, .sameDay)
        XCTAssertEqual(pick?.album, "Midnatt")
        XCTAssertEqual(pick?.year, 2023)
        XCTAssertEqual(pick?.plays, 4)
    }

    func testO2EqualCountsGoToTheMoreRecentYear() {
        let history = plays("A", "One", HomeFixtures.date(2023, 10, 25, 9, 0), count: 3)
            + plays("B", "Two", HomeFixtures.date(2024, 10, 25, 9, 0), count: 3)
        XCTAssertEqual(OnThisDay.pick(history, now: now, calendar: cal)?.album, "B")
    }

    func testO3YearsDoNotMergeAndAYearAgoThisWeekIsTheFallback() {
        let history = plays("A", "One", HomeFixtures.date(2022, 10, 25, 9, 0), count: 2)
            + plays("A", "One", HomeFixtures.date(2023, 10, 25, 9, 0), count: 2)
            + plays("Week", "Three", HomeFixtures.date(2025, 10, 23, 20, 0), count: 3)
            + plays("Far", "Four", HomeFixtures.date(2025, 10, 30, 20, 0), count: 5)
        let pick = OnThisDay.pick(history, now: now, calendar: cal)
        XCTAssertEqual(pick?.kind, .yearAgoThisWeek)
        XCTAssertEqual(pick?.album, "Week")
        XCTAssertEqual(pick?.year, 2025)
        XCTAssertEqual(pick?.plays, 3)
    }

    func testO4ThisYearsPlaysAreNotADayToRemember() {
        XCTAssertNil(OnThisDay.pick(plays("Now", "Five", HomeFixtures.date(2026, 10, 25, 9, 0), count: 5), now: now, calendar: cal))
    }

    func testO5UndatedAndUntitledPlaysAreIgnored() {
        let history = plays("Zero", "Six", Date(timeIntervalSince1970: 0), count: 5)
            + plays("", "Seven", HomeFixtures.date(2023, 10, 25, 9, 0), count: 5)
        XCTAssertNil(OnThisDay.pick(history, now: now, calendar: cal))
    }

    func testO6NamesComeFromTheLatestPlayOfTheGroup() {
        let history = plays("Midnatt", "Solveig", HomeFixtures.date(2023, 10, 25, 9, 0), count: 2)
            + plays("MIDNATT", "Solveig", HomeFixtures.date(2023, 10, 25, 20, 0), count: 1)
        let pick = OnThisDay.pick(history, now: now, calendar: cal)
        XCTAssertEqual(pick?.album, "MIDNATT")
        XCTAssertEqual(pick?.plays, 3)
        XCTAssertEqual(pick?.lastPlayedAt, HomeFixtures.date(2023, 10, 25, 20, 0))
    }

    func testW1WindowsDailyBucketsAndDeltas() {
        let entries = [
            HomePlay(album: "a", artist: "a", at: now.addingTimeInterval(-3600), seconds: 200),
            HomePlay(album: "a", artist: "a", at: now.addingTimeInterval(-2 * 86_400), seconds: 300),
            HomePlay(album: "a", artist: "a", at: now.addingTimeInterval(-(6 * 86_400 + 23 * 3600)), seconds: 100),
            HomePlay(album: "a", artist: "a", at: now.addingTimeInterval(-7 * 86_400), seconds: 50),
            HomePlay(album: "a", artist: "a", at: now.addingTimeInterval(-8 * 86_400), seconds: 60),
            HomePlay(album: "a", artist: "a", at: now.addingTimeInterval(-13 * 86_400), seconds: 70),
            HomePlay(album: "a", artist: "a", at: now.addingTimeInterval(-14 * 86_400), seconds: 80),
            HomePlay(album: "a", artist: "a", at: now.addingTimeInterval(-15 * 86_400), seconds: 90),
            HomePlay(album: "a", artist: "a", at: now.addingTimeInterval(3600), seconds: 999),
            HomePlay(album: "a", artist: "a", at: Date(timeIntervalSince1970: 0), seconds: 999),
        ]
        let glance = WeekGlance.compute(entries, now: now, calendar: cal)
        XCTAssertEqual(glance.plays, 4)
        XCTAssertEqual(glance.seconds, 650)
        XCTAssertEqual(glance.previousPlays, 3)
        XCTAssertEqual(glance.previousSeconds, 210)
        XCTAssertEqual(glance.daily, [0, 0, 0, 0, 1, 0, 1])
        XCTAssertEqual(glance.peakIndex, 6)
        XCTAssertEqual(glance.playsDelta, .up(33))
        XCTAssertEqual(glance.secondsDelta, .up(210))
        XCTAssertTrue(glance.hasPlays)
    }

    func testW2HoursAndMinutesTruncate() {
        XCTAssertTrue(WeekGlance.hoursAndMinutes(51_600) == (14, 20))
        XCTAssertTrue(WeekGlance.hoursAndMinutes(59) == (0, 0))
        XCTAssertTrue(WeekGlance.hoursAndMinutes(-5) == (0, 0))
    }

    func testW3NoPlaysMeansNothingToShow() {
        let glance = WeekGlance.compute([], now: now, calendar: cal)
        XCTAssertFalse(glance.hasPlays)
        XCTAssertNil(glance.peakIndex)
        XCTAssertEqual(glance.daily, [0, 0, 0, 0, 0, 0, 0])
    }
}

enum HomeFixtures {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}

final class HomePromoTests: XCTestCase {

    private func facts(
        _ phase: HomePromo.Phase,
        loaded: Bool = true,
        own: Int = 500,
        welcomeBack: Bool = false,
        proof: Int = 3
    ) -> HomePromo.Facts {
        HomePromo.Facts(phase: phase, entitlementsLoaded: loaded, ownTrackCount: own, welcomeBackOpen: welcomeBack, proofLineCount: proof)
    }

    func testPR1WithoutMusicOfTheirOwnHomeLeadsWithGettingItIn() {
        XCTAssertEqual(HomePromo.card(for: facts(.notStarted, own: 0)), .getStarted)
        XCTAssertEqual(HomePromo.card(for: facts(.purchased, own: 0)), .getStarted)
        XCTAssertEqual(HomePromo.getStarted.placement, .replacesHero)
    }

    func testPR2ATrialWaitingForItsFirstPlaySaysSoUnderTheHero() {
        XCTAssertEqual(HomePromo.card(for: facts(.notStarted)), .trialStartsOnFirstPlay)
        XCTAssertEqual(HomePromo.trialStartsOnFirstPlay.placement, .heroFootnote)
    }

    func testPR3TheValueCardWaitsForTwoDaysAndTwoProofLines() {
        XCTAssertNil(HomePromo.card(for: facts(.trial(daysRemaining: 7))))
        XCTAssertNil(HomePromo.card(for: facts(.trial(daysRemaining: 6))))
        XCTAssertEqual(HomePromo.card(for: facts(.trial(daysRemaining: 5))), .trialValue(daysRemaining: 5))
        XCTAssertNil(HomePromo.card(for: facts(.trial(daysRemaining: 4), proof: 1)))
        XCTAssertEqual(HomePromo.trialValue(daysRemaining: 4).placement, .pageEnd)
    }

    func testPR4TheLastDaySitsUnderTheHero() {
        XCTAssertEqual(HomePromo.card(for: facts(.trial(daysRemaining: 1), proof: 0)), .lastDay)
        XCTAssertEqual(HomePromo.lastDay.placement, .belowHero)
    }

    func testPR5AnEndedTrialSellsOnlyOnceTheEntitlementsConfirmIt() {
        XCTAssertNil(HomePromo.card(for: facts(.expired, loaded: false)))
        XCTAssertEqual(HomePromo.card(for: facts(.expired)), .keepListening(welcomeBack: false))
        XCTAssertEqual(HomePromo.card(for: facts(.expired, welcomeBack: true)), .keepListening(welcomeBack: true))
        XCTAssertEqual(HomePromo.keepListening(welcomeBack: true).placement, .replacesHero)
    }

    func testPR6PaidLibrariesSeeNothing() {
        XCTAssertNil(HomePromo.card(for: facts(.purchased)))
    }
}
