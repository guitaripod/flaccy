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
    private var cancellables = Set<AnyCancellable>()
    private let refreshRequests = PassthroughSubject<Void, Never>()

    private static let coalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(120)

    init() {
        refreshRequests
            .debounce(for: Self.coalesceInterval, scheduler: RunLoop.main)
            .sink { [weak self] in self?.reload() }
            .store(in: &cancellables)
        observeSources()
    }

    private func observeSources() {
        let names: [Notification.Name] = [
            AudioPlayer.trackDidChange,
            AudioPlayer.playbackStateDidChange,
            AudioPlayer.queueDidChange,
            RecentContextStore.didChange,
            HomeLayoutStore.didChange,
            Library.didUpdateNotification,
            PurchaseManager.stateDidChange,
            PurchaseManager.entitlementsDidLoad,
            UIApplication.willEnterForegroundNotification,
        ]
        for name in names {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.refreshRequests.send() }
                .store(in: &cancellables)
        }
    }

    /// Asks for a fresh feed; bursts of requests collapse into one build.
    func refresh() {
        refreshRequests.send()
    }

    /// Builds immediately, for the first appearance and for explicit refreshes.
    func reload() {
        generation += 1
        let mine = generation
        let inputs = HomeFeedInputs.current()
        Task.detached(priority: .userInitiated) { [weak self] in
            let built = Self.build(inputs)
            await MainActor.run {
                guard let self, mine == self.generation else { return }
                self.model = built
                self.hasLoaded = true
                HomePromoOffers.loadIfNeeded(for: built.feed.promo)
                self.onUpdate?(built)
            }
        }
    }

    nonisolated private static func build(_ inputs: HomeFeedInputs) -> HomeScreenModel {
        let feed = HomeFeedBuilder.build(inputs)
        let index = HomeFeedBuilder.AlbumIndex(albums: inputs.albums)
        var covers: [String: [Album]] = [:]
        for mix in feed.mixes {
            covers[mix.id] = HomeFeedBuilder.coverAlbums(mix.tracks, index: index)
        }
        return HomeScreenModel(feed: feed, mixCovers: covers)
    }
}
