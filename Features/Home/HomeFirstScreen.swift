import FlaccyCore
import FlaccyEngine
import Foundation

/// Loads the covers Home's first screen shows before the page is revealed, so
/// it arrives whole rather than filling in tile by tile. A slow read never
/// holds the launch past `budget`.
enum HomeFirstScreen {

    static let budget: TimeInterval = 0.45
    nonisolated private static let jumpTiles = 4
    nonisolated private static let mixCards = 2

    /// The albums whose covers stand on the first screen: the hero's, the
    /// leading Jump Back In tiles' and the first mixes'.
    nonisolated static func albums(in feed: HomeFeed, mixCovers: [String: [Album]]) -> [Album] {
        var hero: [Album] = []
        if feed.promo?.placement != .replacesHero {
            switch feed.hero {
            case .resume: hero = feed.resume?.album.map { [$0] } ?? []
            case .upNext: hero = feed.upNext?.albums ?? []
            case .dayOne: hero = feed.dayOne?.coverAlbums ?? []
            case .empty: break
            }
        }
        let tiles = feed.jumpBackIn.prefix(jumpTiles).flatMap(\.coverAlbums)
        let mixes = feed.mixes.prefix(mixCards).flatMap { mixCovers[$0.id] ?? [] }
        var seen = Set<String>()
        return (hero + tiles + mixes).filter { seen.insert($0.id).inserted }
    }

    static func prewarmCovers(_ albums: [Album]) async {
        guard !albums.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeOnce(continuation)
            let group = DispatchGroup()
            for album in albums {
                group.enter()
                AlbumArtworkCache.shared.loadThumbnail(forAlbum: album.title, artist: album.artist) { _ in group.leave() }
            }
            group.notify(queue: .main) { gate.resume() }
            DispatchQueue.main.asyncAfter(deadline: .now() + budget) { gate.resume() }
        }
    }
}

/// Resumes a continuation the first time it is asked to and ignores the rest,
/// for a wait that ends on whichever of two things happens first.
private final class ResumeOnce {

    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
