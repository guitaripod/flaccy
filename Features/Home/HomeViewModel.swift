import Combine
import FlaccyCore
import Foundation
import MidgarCore
import UIKit

/// What the iPhone's Home renders: the shared feed plus the albums behind
/// each mix's cover, resolved off the main actor alongside it.
nonisolated struct HomeScreenModel: Sendable {
    let feed: HomeFeed
    let mixCovers: [String: [Album]]

    static let empty = HomeScreenModel(feed: .empty, mixCovers: [:])

    /// The album whose cover tints the backdrop behind the hero.
    var backdropAlbum: Album? {
        if feed.promo?.placement == .replacesHero { return nil }
        switch feed.hero {
        case .resume: return feed.resume?.album
        case .upNext: return feed.upNext?.albums.first
        case .dayOne: return feed.dayOne?.coverAlbums.first
        case .empty: return nil
        }
    }
}

/// Builds Home's feed when anything it shows may have changed, off the main
/// actor, and drops a result that a newer request has already overtaken.
@MainActor
final class HomeViewModel {

    private(set) var model: HomeScreenModel = .empty
    private(set) var hasLoaded = false
    var onUpdate: ((HomeScreenModel) -> Void)?

    private var generation = 0
    private var isBuildingFirstFrame = false
    private var cancellables = Set<AnyCancellable>()
    private let refreshRequests = PassthroughSubject<Void, Never>()
    private lazy var launchGate = HomeLaunchGate { [weak self] in self?.refresh() }
    private let historyPrefetch = HomeHistoryPrefetch()
    private var leadLog = HomeLeadLog()

    private static let coalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(120)

    init() {
        refreshRequests
            .debounce(for: Self.coalesceInterval, scheduler: RunLoop.main)
            .sink { [weak self] in self?.reload() }
            .store(in: &cancellables)
        historyPrefetch.start()
        HomeFirstScreen.preloadRemembered()
        observeSources()
    }

    /// Whether the first frame is still waiting for what a launch puts back
    /// (`HomeLaunchGate`). A feed built before then would lead with something
    /// else and change under the person a moment later.
    var awaitsLaunch: Bool {
        !hasLoaded && launchGate.isHolding
    }

    private func observeSources() {
        let names: [Notification.Name] = [
            AudioPlayer.trackDidChange,
            AudioPlayer.playbackStateDidChange,
            AudioPlayer.queueDidChange,
            RecentContextStore.didChange,
            HomeLayoutStore.didChange,
            PurchaseManager.stateDidChange,
            UIApplication.willEnterForegroundNotification,
        ] + HomeLaunchGate.openingNotifications
        for name in names {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &cancellables)
        }
    }

    /// Asks for a fresh feed; bursts of requests collapse into one build. The
    /// first frame skips the wait, since nothing on screen can flicker yet.
    func refresh() {
        if !hasLoaded, !isBuildingFirstFrame {
            reload()
        } else {
            refreshRequests.send()
        }
    }

    /// Builds immediately, for the first appearance and for explicit refreshes.
    /// Until the first frame is up, the build that started first is kept even
    /// when a newer one overtakes it: launch fires a burst of changes, and
    /// restarting on each would hold the page back.
    func reload() {
        guard !awaitsLaunch else { return }
        generation += 1
        let mine = generation
        let began = DispatchTime.now().uptimeNanoseconds
        var clock = HomeBuildClock()
        let inputs = HomeFeedInputs.current()
        clock.lap("inputs")
        let isFirstFrame = !hasLoaded
        if isFirstFrame { isBuildingFirstFrame = true }
        let launchHistory = isFirstFrame ? historyPrefetch.claim() : nil
        Task.detached(priority: .userInitiated) { [weak self, clock] in
            var clock = clock
            if isFirstFrame { SpellingMemo.warm(for: inputs.tracks) }
            clock.lap("spelling")
            let prefetched = await HomeHistoryPrefetch.rows(launchHistory, at: inputs.now)
            clock.lap("wait")
            let built = Self.build(inputs, history: prefetched, clock: &clock)
            let firstScreen = HomeFirstScreen.albums(in: built.feed, mixCovers: built.mixCovers)
            HomeFirstScreen.remember(firstScreen)
            if isFirstFrame {
                let missing = HomeFirstScreen.missingCovers(firstScreen)
                await HomeFirstScreen.prewarmCovers(firstScreen)
                clock.lap("covers \(missing)/\(firstScreen.count)")
            }
            let stages = clock.summary
            await MainActor.run {
                guard let self, mine == self.generation || !self.hasLoaded else { return }
                if isFirstFrame { self.isBuildingFirstFrame = false }
                if !self.hasLoaded {
                    let milliseconds = (DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
                    MidgarLog.info("Home first frame built in \(milliseconds) ms (\(stages))", category: .performance)
                }
                self.leadLog.note(built.feed)
                self.model = built
                self.hasLoaded = true
                HomePromoOffers.loadIfNeeded(for: built.feed.promo)
                self.onUpdate?(built)
            }
        }
    }

    nonisolated private static func build(
        _ inputs: HomeFeedInputs, history: HomeHistoryRows?, clock: inout HomeBuildClock
    ) -> HomeScreenModel {
        let feed = HomeFeedBuilder.build(inputs, history: history, clock: &clock)
        let index = HomeFeedBuilder.AlbumIndex(albums: inputs.albums)
        var covers: [String: [Album]] = [:]
        for mix in feed.mixes {
            covers[mix.id] = HomeFeedBuilder.coverAlbums(mix.tracks, index: index)
        }
        clock.lap("compose")
        return HomeScreenModel(feed: feed, mixCovers: covers)
    }
}
