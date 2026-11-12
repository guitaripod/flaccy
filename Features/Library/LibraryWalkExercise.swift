#if DEBUG && os(iOS)
import FlaccyCore
import MidgarCore
import UIKit

/// Walks every list the library feeds over whatever music is on the device: Home, each Library
/// segment, every album page, every artist page with its Appears On shelf, Search for a spread of
/// letters, and Watch sync. A list that holds one identifier twice raises inside UIKit, so a walk
/// that reaches its end means none did. Logs `LIBRARY WALK PASSED` with the counts.
///
/// Launch with `--exercise-library-walk` after copying a library into Documents. `FLACCY_LANDSCAPE=1`
/// walks in landscape. `FLACCY_WALK_END` leaves the app on one screen for a capture: `home`,
/// `albums`, `songs`, `artists`, `album:<title>`, `artist:<name>`, `search:<query>` or
/// `now-playing:<album title>`, which plays that album and opens the full player.
@MainActor
enum LibraryWalkExercise {

    static let launchArgument = "--exercise-library-walk"

    static func runIfRequested(window: UIWindow, tabs: AppTabBarController, player: PlayerContainerViewController) {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run(window: window, tabs: tabs, player: player) }
    }

    private static func run(window: UIWindow, tabs: AppTabBarController, player: PlayerContainerViewController) async {
        if ProcessInfo.processInfo.environment["FLACCY_LANDSCAPE"] == "1" {
            window.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) // duo-audit:ignore DEBUG-only exercise flag that rotates the scene for captures
        }
        await waitForSettledLibrary()
        let albums = Library.shared.albums
        MidgarLog.info("LibraryWalk: \(albums.count) albums, \(Library.shared.allTracks.count) tracks", category: .general)

        tabs.show(.home)
        await pause(1.5)

        let navigation = tabs.libraryNavigation
        tabs.show(.library)
        for segment in [LibraryViewModel.Segment.albums, .songs, .artists, .playlists] {
            tabs.library.select(segment: segment)
            await pause(0.4)
        }
        tabs.library.select(segment: .albums)

        for album in albums {
            navigation.pushViewController(AlbumDetailViewController(album: album), animated: false)
            await pause(0.15)
            navigation.popToRootViewController(animated: false)
        }

        let artists = tabs.library.viewModel.artists
        for artist in artists {
            let split = tabs.library.viewModel.albumsForArtist(artist.name)
            let page = ArtistDetailViewController(artistName: artist.name, albums: split.credited, appearsOn: split.appearsOn)
            navigation.pushViewController(page, animated: false)
            await pause(0.15)
            navigation.popToRootViewController(animated: false)
        }

        tabs.show(.search)
        for query in ["a", "e", "the", "abbey", "greatest", "東", "🌊", "1"] {
            tabs.search.demoSearch(query: query)
            await pause(0.3)
        }

        tabs.show(.library)
        navigation.pushViewController(WatchSyncViewController(), animated: false)
        await pause(1)
        navigation.popToRootViewController(animated: false)

        MidgarLog.info("LIBRARY WALK PASSED: \(albums.count) album pages, \(artists.count) artist pages", category: .general)
        await end(on: ProcessInfo.processInfo.environment["FLACCY_WALK_END"], tabs: tabs, player: player)
    }

    /// Leaves the app on the screen `FLACCY_WALK_END` names, for a capture after the walk.
    private static func end(on screen: String?, tabs: AppTabBarController, player: PlayerContainerViewController) async {
        guard let screen else { return }
        let navigation = tabs.libraryNavigation
        let (kind, value) = screen.split(separator: ":", maxSplits: 1).map(String.init).pair
        switch kind {
        case "home":
            tabs.show(.home)
        case "albums", "songs", "artists":
            tabs.show(.library)
            tabs.library.select(segment: kind == "albums" ? .albums : kind == "songs" ? .songs : .artists)
        case "album":
            tabs.show(.library)
            guard let album = Library.shared.albums.first(where: { $0.title == value }) else { return }
            navigation.pushViewController(AlbumDetailViewController(album: album), animated: false)
        case "artist":
            tabs.show(.library)
            let split = tabs.library.viewModel.albumsForArtist(value)
            navigation.pushViewController(
                ArtistDetailViewController(artistName: value, albums: split.credited, appearsOn: split.appearsOn), animated: false
            )
        case "search":
            tabs.show(.search)
            tabs.search.demoSearch(query: value)
        case "now-playing":
            guard let album = Library.shared.albums.first(where: { $0.title == value }) ?? Library.shared.albums.first else { return }
            AudioPlayer.shared.play(album.tracks, startingAt: 0)
            await pause(0.8)
            player.expand()
        default:
            MidgarLog.error("LibraryWalk: unknown FLACCY_WALK_END \(screen)", category: .general)
        }
    }

    /// Returns once the library has albums and has stopped loading for two seconds running, or
    /// after three minutes, so a first scan of a large library finishes before the walk starts.
    private static func waitForSettledLibrary() async {
        var quietTicks = 0
        for _ in 0..<360 {
            let busy = Library.shared.isLoading || Library.shared.albums.isEmpty
            quietTicks = busy ? 0 : quietTicks + 1
            if quietTicks >= 4 { return }
            await pause(0.5)
        }
        MidgarLog.error("LibraryWalk: the library never settled", category: .general)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

private extension Array where Element == String {
    var pair: (String, String) { (first ?? "", count > 1 ? self[1] : "") }
}
#endif
