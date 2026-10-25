import MidgarCore
#if DEBUG
import FlaccyCore
import UIKit

/// Opens the iPhone screens for remote libraries for a picture: launch with `--shot-remote <screen>`
/// and `FLACCY_EXERCISE_REMOTE`, where the screen is `servers`, `add-server`, `library` or `album`.
@MainActor
enum RemoteShot {

    static func runIfRequested(nav: UINavigationController) {
        guard let screen = RemoteShotSeed.requestedScreen else { return }
        Task {
            guard let server = await RemoteShotSeed.prepare() else { return }
            switch screen {
            case "add-server": await openAddServer(from: nav)
            case "library": await openLibrary(nav: nav, server: server)
            case "album": await openAlbum(nav: nav, server: server)
            default: await openServers(from: nav)
            }
            RemoteShotSeed.ready(screen)
        }
    }

    private static func openServers(from nav: UINavigationController) async {
        let settings = SettingsViewController()
        let container = UINavigationController(rootViewController: settings)
        nav.present(container, animated: false)
        try? await Task.sleep(for: .seconds(2))
        if let indexPath = settings.dataSource.indexPath(for: .serversExplainer) {
            settings.tableView.scrollToRow(at: indexPath, at: .top, animated: false)
        }
    }

    private static func openAddServer(from nav: UINavigationController) async {
        let form = AddServerViewController(servers: RemoteServersViewModel())
        let container = UINavigationController(rootViewController: form)
        nav.present(container, animated: false)
        try? await Task.sleep(for: .seconds(1))
        if let credentials = RemoteShotSeed.credentials {
            await form.fillForCapture(address: credentials.address, username: credentials.username, password: credentials.password)
        }
    }

    private static func openLibrary(nav: UINavigationController, server: RemoteServerRecord) async {
        guard let library = nav.viewControllers.first as? LibraryViewController else { return }
        library.demoSelect(segment: .songs)
        try? await Task.sleep(for: .seconds(1))
        library.viewModel.setSource(.server(server.id))
        library.updateChips(for: .songs)
        try? await Task.sleep(for: .seconds(2))
    }

    private static func openAlbum(nav: UINavigationController, server: RemoteServerRecord) async {
        let remote = Library.shared.allTracks.filter { $0.remoteSong?.serverID == server.id }
        guard let first = remote.first(where: \.isDownloadedRemote),
              let album = Library.shared.albums.first(where: { $0.title == first.albumTitle && $0.artist == first.artist })
        else { return RemoteShotSeed.fail("no downloaded album to open") }
        nav.pushViewController(AlbumDetailViewController(album: album), animated: false)
        try? await Task.sleep(for: .seconds(2))
    }
}
#endif
