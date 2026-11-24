#if DEBUG && os(iOS)
import FlaccyCore
import MidgarCore
import MidgarUI
import UIKit

/// Walks the screens the static audit named heaviest in a fixed order, with a
/// frame watch line per screen, so a change can be measured against itself on
/// the same device and the same library. Every screen dwells long enough for
/// the watch to count it and scrolls once where it scrolls.
///
/// Launch with `--exercise-perf-walk`. `FLACCY_PERF_SHOTS=1` also writes one
/// PNG per screen into Documents for a capture run; keep it off while
/// measuring, since drawing a snapshot costs main-thread time.
@MainActor
enum PerfWalkExercise {

    static let launchArgument = "--exercise-perf-walk"

    private static let dwell: Double = 3.4
    private static let settle: Double = 0.5

    static func runIfRequested(window: UIWindow, tabs: AppTabBarController, player: PlayerContainerViewController) {
        guard DebugLaunch.arguments.contains(launchArgument) else { return }
        Task { await run(window: window, tabs: tabs, player: player) }
    }

    private static func run(window: UIWindow, tabs: AppTabBarController, player: PlayerContainerViewController) async {
        let shots = ProcessInfo.processInfo.environment["FLACCY_PERF_SHOTS"] == "1"
        MidgarFrameWatch.shared.stop()
        MidgarFrameWatch.shared.start()
        await pause(2)
        dismissOnboarding(over: window)
        await waitForSettledLibrary()
        MidgarLog.info(
            "PerfWalk: \(Library.shared.albums.count) albums, \(Library.shared.allTracks.count) tracks",
            category: .general
        )

        await measure("Home", shots: shots, window: window, entering: {
            tabs.show(.home)
            await pause(settle)
        }, scrolling: {
            scroll(tabs.home.collectionView)
        })

        await measure("Library albums", shots: shots, window: window, entering: {
            tabs.show(.library)
            tabs.library.select(segment: .albums)
            await pause(settle)
        }, scrolling: {
            scroll(tabs.library.collectionView)
        })

        await measure("Library songs", shots: shots, window: window, entering: {
            tabs.library.select(segment: .songs)
            await pause(settle)
        }, scrolling: {
            scroll(tabs.library.collectionView)
        })

        let album = Library.shared.albums.first

        await measure("Album detail", shots: shots, window: window, entering: {
            guard let album else { return }
            tabs.libraryNavigation.pushViewController(AlbumDetailViewController(album: album), animated: false)
        }, scrolling: {
            guard let detail = tabs.libraryNavigation.topViewController as? AlbumDetailViewController else { return }
            scroll(detail.tableView)
        })

        await measure("Artist detail", shots: shots, window: window, entering: {
            guard let artist = tabs.library.viewModel.artists.first else { return }
            let split = tabs.library.viewModel.albumsForArtist(artist.name)
            tabs.libraryNavigation.pushViewController(
                ArtistDetailViewController(artistName: artist.name, albums: split.credited, appearsOn: split.appearsOn),
                animated: false
            )
        }, scrolling: nil)

        await measure("Search results", shots: shots, window: window, entering: {
            tabs.libraryNavigation.popToRootViewController(animated: false)
            tabs.show(.search)
            tabs.search.demoSearch(query: "the")
        }, scrolling: nil)

        await measure("Now playing", shots: shots, window: window, entering: {
            if let album, !album.tracks.isEmpty {
                AudioPlayer.shared.play(album.tracks, startingAt: 0)
                await pause(0.8)
            }
            player.expand()
            await pause(1.2)
        }, scrolling: nil)

        await measure("Queue", shots: shots, window: window, entering: {
            player.expandShowingQueue()
            await pause(0.6)
        }, scrolling: nil)

        await measure("Paywall", shots: shots, window: window, entering: {
            player.collapse()
            await pause(0.8)
            guard var top = window.rootViewController else { return }
            while let presented = top.presentedViewController { top = presented }
            PaywallViewController.presentSheet(from: top)
            await pause(1.2)
        }, scrolling: nil)

        MidgarFrameWatch.shared.report("the walk's end")
        MidgarLog.info("PERF WALK PASSED", category: .general)
    }

    /// Dwells on the screen `entering` brings up, counts its frames, scrolls it
    /// once, and closes the stretch under its name.
    private static func measure(
        _ name: String,
        shots: Bool,
        window: UIWindow,
        entering: () async -> Void,
        scrolling: (() -> Void)?
    ) async {
        await entering()
        MidgarFrameWatch.shared.report("\(name) entry")
        await pause(settle)
        await pause(dwell)
        scrolling?()
        await pause(1.2)
        MidgarFrameWatch.shared.report(name)
        if shots {
            await pause(0.4)
            PaywallShot.capture(window, as: "perf-\(slug(name)).png", in: .cachesDirectory)
        }
    }

    /// Closes the showcase and the welcome a fresh container raises over the
    /// tabs, so the walk starts on the app the person uses.
    private static func dismissOnboarding(over window: UIWindow) {
        guard let root = window.rootViewController else { return }
        if root.presentedViewController != nil {
            root.dismiss(animated: false)
        }
        if let tabs = root.children.compactMap({ $0 as? AppTabBarController }).first, tabs.library.isShowingDebut {
            tabs.library.finishDebut()
        }
    }

    private static func scroll(_ scrollView: UIScrollView?) {
        guard let scrollView else { return }
        let limit = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
        let target = min(scrollView.contentOffset.y + 900, limit)
        guard target > scrollView.contentOffset.y else { return }
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            scrollView.contentOffset.y = target
        }
    }

    private static func slug(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// Returns once the library holds albums and has stopped loading for two
    /// seconds running, or after a minute, so a first scan finishes first.
    private static func waitForSettledLibrary() async {
        var quietTicks = 0
        for _ in 0..<120 {
            let busy = Library.shared.isLoading || Library.shared.albums.isEmpty
            quietTicks = busy ? 0 : quietTicks + 1
            if quietTicks >= 4 { return }
            await pause(0.5)
        }
        MidgarLog.error("PerfWalk: the library never settled", category: .general)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
#endif
