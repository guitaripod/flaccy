import FlaccyCore
import Foundation

nonisolated enum HomeSectionID: Hashable, Sendable {
    case banners
    case hero
    case heroWithJump
    case promoNote
    case promoCard
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
    case getStarted
    case promoCard
    case promoNote
    case jumpHeader
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
        for model: HomeScreenModel, showsRunwayBanner: Bool, showsStatusBanner: Bool, isWide: Bool = false
    ) -> [(section: HomeSectionID, items: [HomeItem])] {
        let feed = model.feed
        var plan: [(HomeSectionID, [HomeItem])] = []

        var banners: [HomeItem] = []
        if showsRunwayBanner { banners.append(.runwayBanner) }
        if showsStatusBanner { banners.append(.statusBanner) }
        if !banners.isEmpty { plan.append((.banners, banners)) }

        let promo = feed.promo
        let heroItem = heroItem(for: promo)
        if feed.hero == .empty {
            plan.append((.hero, [promo == nil ? .getStarted : heroItem]))
            return plan
        }
        var blocks = feed.blocks.filter { $0 != .single(.resume) }[...]
        if isWide, blocks.first == .single(.jumpBackIn), !feed.jumpBackIn.isEmpty {
            blocks = blocks.dropFirst()
            plan.append((.heroWithJump, [heroItem, .jumpHeader] + feed.jumpBackIn.map { .jump($0.context) }))
        } else {
            plan.append((.hero, [heroItem]))
        }
        switch promo?.placement {
        case .heroFootnote: plan.append((.promoNote, [.promoNote]))
        case .belowHero: plan.append((.promoCard, [.promoCard]))
        case .replacesHero, .pageEnd, nil: break
        }

        for block in blocks {
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
        if promo?.placement == .pageEnd { plan.append((.promoCard, [.promoCard])) }
        plan.append((.footer, [.edit]))
        return plan
    }

    /// What stands where the hero stands: the hero itself, or the card that
    /// replaces it.
    private static func heroItem(for promo: HomePromo?) -> HomeItem {
        guard let promo, promo.placement == .replacesHero else { return .hero }
        return promo == .getStarted ? .getStarted : .promoCard
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
