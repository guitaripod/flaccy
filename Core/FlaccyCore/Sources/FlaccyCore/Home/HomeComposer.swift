import Foundation

/// What leads Home. `resume` picks up a paused session, `upNext` offers the
/// next decision (a mix) while music plays or when there is nothing to resume,
/// `dayOne` is a library with no listening history yet, `empty` no library.
public enum HomeHero: Equatable, Sendable {
    case resume
    case upNext
    case dayOne
    case empty
}

/// The facts Home is composed from, gathered by each client from its own
/// library, player and history.
public struct HomeAvailability: Equatable, Sendable {
    public var libraryTrackCount: Int
    public var hasListeningHistory: Bool
    public var isPlaying: Bool
    public var canResume: Bool
    public var jumpBackInCount: Int
    public var recentlyAddedCount: Int
    public var hasOnThisDay: Bool
    public var hasWeekPlays: Bool

    public init(
        libraryTrackCount: Int,
        hasListeningHistory: Bool,
        isPlaying: Bool,
        canResume: Bool,
        jumpBackInCount: Int,
        recentlyAddedCount: Int,
        hasOnThisDay: Bool,
        hasWeekPlays: Bool
    ) {
        self.libraryTrackCount = libraryTrackCount
        self.hasListeningHistory = hasListeningHistory
        self.isPlaying = isPlaying
        self.canResume = canResume
        self.jumpBackInCount = jumpBackInCount
        self.recentlyAddedCount = recentlyAddedCount
        self.hasOnThisDay = hasOnThisDay
        self.hasWeekPlays = hasWeekPlays
    }
}

/// One row of Home: a section on its own, or two compact sections that are
/// neighbours in the person's order sitting side by side.
public enum HomeBlock: Equatable, Sendable {
    case single(HomeSection)
    case pair(HomeSection, HomeSection)
}

/// Decides what Home shows and in what shape. Pure, so every client and both
/// languages answer the same facts the same way.
public enum HomeComposer {

    public static let jumpBackInLimit = 6
    public static let minimumJumpBackIn = 2
    public static let recentlyAddedLimit = 12

    /// The suggested-playlist identifiers in the order the hero prefers them.
    public static let heroMixPreference = ["tonights-spin", "heavy-rotation", "on-repeat", "rediscover", "crate-dig"]

    public static func hero(for facts: HomeAvailability) -> HomeHero {
        guard facts.libraryTrackCount > 0 else { return .empty }
        if !facts.isPlaying && facts.canResume { return .resume }
        return facts.hasListeningHistory ? .upNext : .dayOne
    }

    public static func shows(_ section: HomeSection, given facts: HomeAvailability) -> Bool {
        switch section {
        case .resume: hero(for: facts) != .empty
        case .jumpBackIn: facts.jumpBackInCount >= minimumJumpBackIn
        case .madeForYou: facts.libraryTrackCount > 0
        case .recentlyAdded: facts.recentlyAddedCount > 0
        case .onThisDay: facts.hasOnThisDay
        case .thisWeek: facts.hasWeekPlays
        }
    }

    /// The visible sections that have something to show, with neighbouring
    /// compact sections paired from the top down.
    public static func blocks(layout: HomeLayout, facts: HomeAvailability) -> [HomeBlock] {
        let sections = layout.visible.filter { shows($0, given: facts) }
        var blocks: [HomeBlock] = []
        var index = 0
        while index < sections.count {
            let section = sections[index]
            if section.isCompact, index + 1 < sections.count, sections[index + 1].isCompact {
                blocks.append(.pair(section, sections[index + 1]))
                index += 2
            } else {
                blocks.append(.single(section))
                index += 1
            }
        }
        return blocks
    }

    /// The first of `available` in `heroMixPreference` order, else the first
    /// one offered.
    public static func heroMix(among available: [String]) -> String? {
        heroMixPreference.first(where: available.contains) ?? available.first
    }
}
