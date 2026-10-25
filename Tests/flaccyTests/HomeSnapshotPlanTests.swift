import FlaccyCore
import XCTest
@testable import flaccy

nonisolated final class HomeSnapshotPlanTests: XCTestCase {

    private func feed(hero: HomeHero, blocks: [HomeBlock]) -> HomeFeed {
        HomeFeed(
            facts: HomeFeed.empty.facts, hero: hero, blocks: blocks, resume: nil, upNext: nil, dayOne: nil,
            jumpBackIn: [], mixes: [], recentlyAdded: [], onThisDay: nil, week: nil
        )
    }

    @MainActor func testAnEmptyLibraryShowsOnlyTheEmptyInvitation() {
        let plan = HomeSnapshotPlan.sections(
            for: HomeScreenModel(feed: feed(hero: .empty, blocks: []), mixCovers: [:]),
            showsRunwayBanner: false, showsStatusBanner: false
        )
        XCTAssertEqual(plan.map(\.section), [.hero])
        XCTAssertEqual(plan.first?.items, [.empty])
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
