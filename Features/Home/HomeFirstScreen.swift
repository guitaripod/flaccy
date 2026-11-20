import FlaccyCore
import FlaccyEngine
import Foundation
import Synchronization

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

    nonisolated private static let rememberedKey = "flaccy.home.firstScreenCovers"

    /// Keeps the albums of the screen Home just built for the next launch to
    /// start on.
    nonisolated static func remember(_ albums: [Album]) {
        let pairs = albums.map { [$0.title, $0.artist] }
        guard UserDefaults.standard.array(forKey: rememberedKey) as? [[String]] != pairs else { return }
        UserDefaults.standard.set(pairs, forKey: rememberedKey)
    }

    /// Starts loading the covers the last Home screen stood on while the
    /// library is still coming back. Home opens on the same page through a
    /// listening day, so these are almost always the covers its first frame
    /// waits for, and they are in memory by the time it is built.
    static func preloadRemembered() {
        guard let pairs = UserDefaults.standard.array(forKey: rememberedKey) as? [[String]] else { return }
        for pair in pairs where pair.count == 2 {
            let (title, artist) = (pair[0], pair[1])
            AlbumArtworkCache.shared.loadThumbnail(forAlbum: title, artist: artist) { image in
                noteCover(image, title: title, artist: artist)
            }
        }
    }

    nonisolated private static let coverlessKey = "flaccy.home.coverlessAlbums"
    nonisolated private static let coverlessLimit = 200
    nonisolated private static let coverless = Mutex<Set<String>>(
        Set(UserDefaults.standard.stringArray(forKey: coverlessKey) ?? [])
    )

    /// Keeps, across launches, the albums found to have no cover at all, so a
    /// first frame never waits for the same empty answer again; an album whose
    /// cover turns up later drops off the list the next time it loads.
    private static func noteCover(_ image: PlatformImage?, title: String, artist: String) {
        let key = coverKey(title: title, artist: artist)
        let changed = coverless.withLock { known -> [String]? in
            if image == nil, known.count >= coverlessLimit { known.removeAll() }
            let moved = image == nil ? known.insert(key).inserted : known.remove(key) != nil
            return moved ? known.sorted() : nil
        }
        if let changed { UserDefaults.standard.set(changed, forKey: coverlessKey) }
    }

    nonisolated private static func coverKey(title: String, artist: String) -> String {
        title + "\u{0}" + artist
    }

    nonisolated private static func isKnownCoverless(_ album: Album) -> Bool {
        coverless.withLock { $0.contains(coverKey(title: album.title, artist: album.artist)) }
    }

    /// How many of `albums` the first frame still has to wait for, for its log line.
    nonisolated static func missingCovers(_ albums: [Album]) -> Int {
        albums.count { AlbumArtworkCache.shared.thumbnail(forAlbum: $0.title, artist: $0.artist) == nil && !isKnownCoverless($0) }
    }

    static func prewarmCovers(_ albums: [Album]) async {
        let albums = albums.filter { !isKnownCoverless($0) }
        guard !albums.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeOnce(continuation)
            let group = DispatchGroup()
            for album in albums {
                group.enter()
                AlbumArtworkCache.shared.loadThumbnail(forAlbum: album.title, artist: album.artist) { image in
                    noteCover(image, title: album.title, artist: album.artist)
                    group.leave()
                }
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
