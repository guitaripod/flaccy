import FlaccyCore
import XCTest
@testable import flaccy

nonisolated final class HomeSnapshotPlanTests: XCTestCase {

    private func feed(hero: HomeHero, blocks: [HomeBlock], promo: HomePromo? = nil) -> HomeFeed {
        HomeFeed(
            facts: HomeFeed.empty.facts, hero: hero, blocks: blocks, resume: nil, upNext: nil, dayOne: nil,
            jumpBackIn: [], mixes: [], recentlyAdded: [], onThisDay: nil, week: nil, promo: promo
        )
    }

    private func plan(_ feed: HomeFeed, isWide: Bool = false) -> [(section: HomeSectionID, items: [HomeItem])] {
        HomeSnapshotPlan.sections(
            for: HomeScreenModel(feed: feed, mixCovers: [:]), showsRunwayBanner: false, showsStatusBanner: false, isWide: isWide
        )
    }

    @MainActor func testAnEmptyLibraryShowsOnlyTheGetStartedCard() {
        let plan = plan(feed(hero: .empty, blocks: [], promo: .getStarted))
        XCTAssertEqual(plan.map(\.section), [.hero])
        XCTAssertEqual(plan.first?.items, [.getStarted])
    }

    @MainActor func testGetStartedTakesTheHeroSlotAndTheRestOfHomeStays() {
        let plan = plan(feed(hero: .dayOne, blocks: [.single(.madeForYou)], promo: .getStarted))
        XCTAssertEqual(plan.map(\.section), [.hero, .madeForYou, .footer])
        XCTAssertEqual(plan[0].items, [.getStarted])
    }

    @MainActor func testKeepListeningTakesTheHeroSlotWhereverTheHeroWouldBe() {
        let promo = HomePromo.keepListening(welcomeBack: true)
        let item = HomeFeed.Item(
            context: PlaybackContext(kind: .album, id: "a", title: "A", subtitle: "B"), coverAlbums: [], trackCount: 3
        )
        let wide = HomeFeed(
            facts: HomeFeed.empty.facts, hero: .dayOne, blocks: [.single(.resume), .single(.jumpBackIn)],
            resume: nil, upNext: nil, dayOne: nil, jumpBackIn: [item], mixes: [], recentlyAdded: [],
            onThisDay: nil, week: nil, promo: promo
        )
        XCTAssertEqual(plan(wide, isWide: true)[0].items, [.promoCard, .jumpHeader, .jump(item.context)])
        XCTAssertEqual(plan(wide)[0].items, [.promoCard])
    }

    @MainActor func testTheTrialNoteSitsRightUnderTheHero() {
        let plan = plan(feed(hero: .dayOne, blocks: [.single(.madeForYou)], promo: .trialStartsOnFirstPlay))
        XCTAssertEqual(plan.map(\.section), [.hero, .promoNote, .madeForYou, .footer])
        XCTAssertEqual(plan[0].items, [.hero])
        XCTAssertEqual(plan[1].items, [.promoNote])
    }

    @MainActor func testTheLastDayCardSitsBelowTheHeroAndTheValueCardClosesThePage() {
        let blocks: [HomeBlock] = [.single(.madeForYou)]
        let below = plan(feed(hero: .dayOne, blocks: blocks, promo: .lastDay))
        XCTAssertEqual(below.map(\.section), [.hero, .promoCard, .madeForYou, .footer])
        let end = plan(feed(hero: .dayOne, blocks: blocks, promo: .trialValue(daysRemaining: 4)))
        XCTAssertEqual(end.map(\.section), [.hero, .madeForYou, .promoCard, .footer])
        XCTAssertEqual(end[2].items, [.promoCard])
    }

    @MainActor func testNoPromoLeavesHomeUntouched() {
        let plan = plan(feed(hero: .dayOne, blocks: [.single(.madeForYou)]))
        XCTAssertEqual(plan.map(\.section), [.hero, .madeForYou, .footer])
    }

    @MainActor func testBannersLeadAndAPairShareOneRowBeforeTheFooter() {
        let model = HomeScreenModel(
            feed: feed(hero: .dayOne, blocks: [.single(.madeForYou), .pair(.onThisDay, .thisWeek)]),
            mixCovers: [:]
        )
        let plan = HomeSnapshotPlan.sections(for: model, showsRunwayBanner: true, showsStatusBanner: true)
        XCTAssertEqual(plan.map(\.section), [.banners, .hero, .madeForYou, .pair, .footer])
        XCTAssertEqual(plan[0].items, [.runwayBanner, .statusBanner])
        XCTAssertEqual(plan[3].items, [.memory, .week])
    }

    @MainActor func testMadeForYouAlwaysHasRadioAndAPlaceholderUntilTwoMixesExist() {
        let model = HomeScreenModel(feed: feed(hero: .dayOne, blocks: [.single(.madeForYou)]), mixCovers: [:])
        let plan = HomeSnapshotPlan.sections(for: model, showsRunwayBanner: false, showsStatusBanner: false)
        XCTAssertEqual(plan[1].items, [.libraryRadio, .moreMixes])
    }

    @MainActor func testAWideWindowPutsTheHeroAndJumpBackInInOneRow() {
        let item = HomeFeed.Item(
            context: PlaybackContext(kind: .album, id: "a", title: "A", subtitle: "B"), coverAlbums: [], trackCount: 3
        )
        let wide = HomeFeed(
            facts: HomeFeed.empty.facts, hero: .dayOne,
            blocks: [.single(.resume), .single(.jumpBackIn), .single(.madeForYou)],
            resume: nil, upNext: nil, dayOne: nil, jumpBackIn: [item], mixes: [], recentlyAdded: [],
            onThisDay: nil, week: nil
        )
        let model = HomeScreenModel(feed: wide, mixCovers: [:])
        let narrowPlan = HomeSnapshotPlan.sections(for: model, showsRunwayBanner: false, showsStatusBanner: false)
        XCTAssertEqual(narrowPlan.map(\.section), [.hero, .jumpBackIn, .madeForYou, .footer])
        let widePlan = HomeSnapshotPlan.sections(for: model, showsRunwayBanner: false, showsStatusBanner: false, isWide: true)
        XCTAssertEqual(widePlan.map(\.section), [.heroWithJump, .madeForYou, .footer])
        XCTAssertEqual(widePlan[0].items, [.hero, .jumpHeader, .jump(item.context)])
    }
}
