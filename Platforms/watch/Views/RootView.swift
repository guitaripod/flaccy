import FlaccyCore
import SwiftUI

enum Route: Hashable {
    case album(MediaAlbum)
    case artists
    case artist(String)
    case storage
    case nowPlaying
}

struct RootView: View {

    @Environment(WatchAudioPlayer.self) private var player
    @Environment(WatchLibraryStore.self) private var store
    @Environment(WatchSyncStatus.self) private var syncStatus
    @State private var path = NavigationPath()
    @State private var pendingRemovals = PendingRemovals()

    var body: some View {
        NavigationStack(path: $path) {
            LibraryView(
                onOpen: { path.append($0) },
                onShowNowPlaying: { path.append(Route.nowPlaying) }
            )
            .screenshotEnvironment()
            .navigationDestination(for: Route.self) { route in
                destination(for: route)
            }
        }
        .environment(pendingRemovals)
        .task { await LibraryShots.run(status: syncStatus, store: store, path: $path) }
        #if targetEnvironment(simulator)
        .task { await autoNavigateForScreenshots() }
        #endif
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        screen(for: route).screenshotEnvironment()
    }

    @ViewBuilder
    private func screen(for route: Route) -> some View {
        switch route {
        case .album(let album):
            AlbumDetailView(
                album: album,
                onShowNowPlaying: { path.append(Route.nowPlaying) },
                onRemoved: popToLibrary
            )
        case .artists:
            ArtistsView(onOpen: { path.append($0) })
        case .artist(let name):
            ArtistAlbumsView(artist: name, onOpen: { path.append($0) })
        case .storage:
            StorageView(onRemovedAll: popToLibrary)
        case .nowPlaying:
            NowPlayingView()
        }
    }

    /// After music is removed the screens that showed it no longer have
    /// anything to say, so the stack returns to the library rather than
    /// leaving the person on a page about an album that is gone.
    private func popToLibrary() {
        path = NavigationPath()
    }

    #if targetEnvironment(simulator)
    /// Simulator-only screenshot harness: `--shot-album <name>` opens that
    /// album, and `--shot-play <track>` additionally starts playback and lands
    /// on Now Playing (`--shot-seek <seconds>` then moves the playhead), so an agent can capture marketing frames without
    /// driving the watch UI by hand.
    private func autoNavigateForScreenshots() async {
        let args = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        guard value(after: "--shot-album") != nil || value(after: "--shot-play") != nil else { return }

        for _ in 0..<50 where store.albums.isEmpty {
            try? await Task.sleep(for: .milliseconds(200))
        }

        if let albumName = value(after: "--shot-album"),
           let album = store.albums.first(where: { $0.title.localizedCaseInsensitiveContains(albumName) }) {
            path.append(Route.album(album))
        }
        if let trackName = value(after: "--shot-play"),
           let track = store.allTracks.first(where: { $0.title.localizedCaseInsensitiveContains(trackName) }) {
            let album = store.albums.first { $0.items.contains(where: { $0.id == track.id }) }
            let queue = album?.items ?? [track]
            let index = queue.firstIndex(where: { $0.id == track.id }) ?? 0
            player.play(queue, startingAt: index)
            try? await Task.sleep(for: .seconds(1))
            path.append(Route.nowPlaying)
            if let seconds = value(after: "--shot-seek").flatMap(Double.init) {
                await seekOnceLoaded(to: seconds)
            }
        }
    }

    /// `--shot-seek <seconds>` lands Now Playing mid-track. The player only
    /// accepts a seek once its item exists, so the request is repeated until
    /// the playhead is where it was asked to be.
    private func seekOnceLoaded(to seconds: TimeInterval) async {
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(500))
            player.seek(to: seconds)
            try? await Task.sleep(for: .milliseconds(300))
            if abs(player.currentTime - seconds) < 2 { return }
        }
    }
    #endif
}
