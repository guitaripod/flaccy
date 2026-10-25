import MidgarCore
#if DEBUG
import FlaccyCore
import UIKit

/// Opens the screens that show the New mix chip on a song the library has just
/// seen re-exported, for a picture: launch with `--shot-new-mix <screen>`, where
/// the screen is `album`, `queue`, `now-playing` or `playlist`.
@MainActor
enum NewMixShot {

    static func runIfRequested(tabs: AppTabBarController, player: PlayerContainerViewController) {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: ReexportExercise.shotArgument) else { return }
        let screen = flag + 1 < arguments.count ? arguments[flag + 1] : "album"
        Task {
            guard let track = await ReexportExercise.seedRevisedSong() else { return }
            AudioPlayer.shared.play([track], startingAt: 0)
            try? await Task.sleep(for: .seconds(1))
            tabs.show(.library)
            open(screen, for: track, nav: tabs.libraryNavigation, player: player)
            MidgarLog.info("NEW MIX SHOT OPENED: \(screen)", category: .content)
        }
    }

    private static func open(
        _ screen: String, for track: Track, nav: UINavigationController, player: PlayerContainerViewController
    ) {
        switch screen {
        case "queue":
            player.expandShowingQueue()
        case "now-playing":
            player.expand()
        case "playlist":
            guard let playlist = try? DatabaseManager.shared.createPlaylist(name: "New Mix Shot"),
                  let id = playlist.id else { return }
            let paths = Library.shared.allTracks
                .filter { $0.albumTitle == ReexportExercise.shotAlbumTitle }
                .map { LibraryPaths.relativePath(of: $0.fileURL) }
            try? DatabaseManager.shared.addTracksToPlaylist(playlistId: id, trackFileURLs: paths)
            nav.pushViewController(PlaylistDetailViewController(playlistId: id, playlistName: playlist.name), animated: false)
        default:
            guard let album = Library.shared.albums.first(where: { $0.title == track.albumTitle }) else { return }
            nav.pushViewController(AlbumDetailViewController(album: album), animated: false)
        }
    }
}
#endif
