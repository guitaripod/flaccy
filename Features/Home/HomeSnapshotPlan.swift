import FlaccyCore
import Foundation

nonisolated enum HomeSectionID: Hashable, Sendable {
    case banners
    case hero
    case jumpBackIn
    case madeForYou
    case recentlyAdded
    case onThisDay
    case thisWeek
    case pair
    case footer
}

nonisolated enum HomeItem: Hashable, Sendable {
    case runwayBanner
    case statusBanner
    case hero
    case empty
    case jump(PlaybackContext)
    case mix(String)
    case libraryRadio
    case moreMixes
    case recent(String)
    case memory
    case week
    case edit
}

/// Which sections Home shows, in order, and what each holds. Pure, so the
/// arrangement a feed and a layout produce can be tested without a screen.
nonisolated enum HomeSnapshotPlan {

    static let minimumMixCards = 2

    static func sections(
        for model: HomeScreenModel, showsRunwayBanner: Bool, showsStatusBanner: Bool
    ) -> [(section: HomeSectionID, items: [HomeItem])] {
        let feed = model.feed
        var plan: [(HomeSectionID, [HomeItem])] = []

        var banners: [HomeItem] = []
        if showsRunwayBanner { banners.append(.runwayBanner) }
        if showsStatusBanner { banners.append(.statusBanner) }
        if !banners.isEmpty { plan.append((.banners, banners)) }

        if feed.hero == .empty {
            plan.append((.hero, [.empty]))
            return plan
        }
        plan.append((.hero, [.hero]))

        for block in feed.blocks {
            switch block {
            case .single(let section):
                if let entry = entry(for: section, model: model) { plan.append(entry) }
            case .pair(let first, let second):
                if first == .onThisDay, second == .thisWeek {
                    plan.append((.pair, [.memory, .week]))
                } else if first == .thisWeek, second == .onThisDay {
                    plan.append((.pair, [.week, .memory]))
                }
            }
        }
        plan.append((.footer, [.edit]))
        return plan
    }

    private static func entry(for section: HomeSection, model: HomeScreenModel) -> (HomeSectionID, [HomeItem])? {
        let feed = model.feed
        switch section {
        case .resume:
            return nil
        case .jumpBackIn:
            return (.jumpBackIn, feed.jumpBackIn.map { .jump($0.context) })
        case .madeForYou:
            var items: [HomeItem] = feed.mixes.map { .mix($0.id) }
            items.append(.libraryRadio)
            if feed.mixes.count < minimumMixCards { items.append(.moreMixes) }
            return (.madeForYou, items)
        case .recentlyAdded:
            return (.recentlyAdded, feed.recentlyAdded.map { .recent($0.id) })
        case .onThisDay:
            return (.onThisDay, [.memory])
        case .thisWeek:
            return (.thisWeek, [.week])
        }
    }
}
