import FlaccyCore
import SwiftUI

enum Route: Hashable {
    case album(MediaAlbum)
    case nowPlaying
}

struct RootView: View {

    @Environment(WatchAudioPlayer.self) private var player
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            LibraryView(
                onOpenAlbum: { path.append(Route.album($0)) },
                onShowNowPlaying: { path.append(Route.nowPlaying) }
            )
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .album(let album):
                    AlbumDetailView(album: album, onShowNowPlaying: { path.append(Route.nowPlaying) })
                case .nowPlaying:
                    NowPlayingView()
                }
            }
        }
        #if targetEnvironment(simulator)
        .task { await autoNavigateForScreenshots() }
        #endif
    }

    #if targetEnvironment(simulator)
    @Environment(WatchLibraryStore.self) private var store

    /// Simulator-only screenshot harness: `--shot-album <name>` opens that
    /// album, and `--shot-play <track>` additionally starts playback and lands
    /// on Now Playing, so an agent can capture marketing frames without
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
        }
    }
    #endif
}
