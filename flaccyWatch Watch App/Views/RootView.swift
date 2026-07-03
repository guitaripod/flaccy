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
    }
}
