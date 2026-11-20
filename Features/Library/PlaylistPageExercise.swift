import MidgarCore
#if DEBUG
import FlaccyCore
import UIKit

/// Walks the remastered playlist page on a device without a touch, over a
/// playlist it makes from the device's own library and deletes afterwards:
/// the page lists what the database holds, an addition skips a song already
/// there, a drag is one commit, a removal comes back where it stood on Undo, a
/// sort is only a view, and a copy keeps the songs in their order. Each check
/// logs `PlaylistPageExercise PASS/FAIL`, and the run ends with
/// `PLAYLIST PAGE EXERCISE PASSED` or `FAILED`. Launch with
/// `--exercise-playlist-page`.
@MainActor
enum PlaylistPageExercise {

    static let launchArgument = "--exercise-playlist-page"

    private static var results: [Bool] = []

    static func runIfRequested(window: UIWindow?) {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run(window: window) }
    }

    private static func run(window: UIWindow?) async {
        guard await waitUntil(seconds: 60, { !Library.shared.allTracks.isEmpty }) else {
            return finish("the library never loaded")
        }
        try? await Task.sleep(for: .seconds(2))
        guard let host = topController(of: window) else { return finish("no screen to present from") }
        let tracks = Array(Library.shared.allTracks.filter { !$0.isUnavailableOffline }.prefix(6))
        guard tracks.count >= 5 else { return finish("the library has fewer than five songs") }

        let name = "Page Exercise \(UUID().uuidString.prefix(6))"
        guard let playlist = PlaylistWriter.create(named: name, with: Array(tracks.prefix(4)), in: nil),
              let id = playlist.id else { return finish("a playlist could not be made") }
        let detail = PlaylistDetailViewController(playlistId: id, playlistName: name)
        let navigation = UINavigationController(rootViewController: detail)
        navigation.modalPresentationStyle = .fullScreen
        let opened = CACurrentMediaTime()
        host.present(navigation, animated: true)
        check("the page lists the four songs", await waitUntil(seconds: 10) { detail.rows.count == 4 })
        MidgarLog.info("PlaylistPageExercise first rows after \(Int((CACurrentMediaTime() - opened) * 1000)) ms", category: .general)

        let addition = PlaylistWriter.add([tracks[4], tracks[0]], toPlaylist: id, named: name, in: nil)
        check("an addition skips the song the playlist holds", addition?.added.count == 1 && addition?.alreadyIn.count == 1)
        check("the page shows the added song", await waitUntil(seconds: 5) { detail.rows.count == 5 })

        let before = detail.rows.map(\.entryId)
        detail.moveRow(from: 0, to: 3)
        let moved = (try? DatabaseManager.shared.fetchPlaylistTracks(playlistId: id))?.compactMap(\.id) ?? []
        check("a drag is written as the page shows it", moved == detail.rows.map(\.entryId) && moved.first == before[1])

        try? await Task.sleep(for: .milliseconds(400))
        let order = detail.rows.map(\.entryId)
        let beforeRemoval = (try? DatabaseManager.shared.fetchPlaylistTracks(playlistId: id))?.map(\.trackFileURL) ?? []
        detail.remove(entryIds: [order[2]])
        check("a removal leaves four songs", await waitUntil(seconds: 5) { detail.rows.count == 4 })
        detail.undoManager?.undo()
        check("Undo puts the song back", await waitUntil(seconds: 5) { detail.rows.count == 5 })
        let files = (try? DatabaseManager.shared.fetchPlaylistTracks(playlistId: id))?.map(\.trackFileURL) ?? []
        check("the song is back where it stood", files == beforeRemoval)

        detail.setOrder(.title)
        let titles = detail.shownRows.compactMap { $0.track?.title }
        let sortedTitles = titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        check("Title order sorts the page", titles == sortedTitles)
        let stored = (try? DatabaseManager.shared.fetchPlaylistTracks(playlistId: id))?.map(\.trackFileURL) ?? []
        check("a sort leaves the playlist's own order alone", stored == files)
        detail.setOrder(.playlist)

        let copy = PlaylistCommands.duplicate(id: id, name: name, in: nil)
        let copied = copy?.id.flatMap { try? DatabaseManager.shared.fetchPlaylistTracks(playlistId: $0) }?.map(\.trackFileURL) ?? []
        check("a copy keeps the songs in their order", copied == files)

        _ = await waitUntil(seconds: 8) { !detail.suggestions.isEmpty }
        MidgarLog.info("PlaylistPageExercise suggestions shown: \(detail.suggestions.count)", category: .general)

        navigation.dismiss(animated: true)
        try? DatabaseManager.shared.deletePlaylist(id: id)
        if let copyId = copy?.id { try? DatabaseManager.shared.deletePlaylist(id: copyId) }
        let passed = results.allSatisfy { $0 }
        let line = "PLAYLIST PAGE EXERCISE \(passed ? "PASSED" : "FAILED"): \(results.filter { $0 }.count) of \(results.count)"
        if passed { MidgarLog.info(line, category: .general) } else { MidgarLog.error(line, category: .general) }
    }

    private static func check(_ name: String, _ passed: Bool) {
        results.append(passed)
        let line = "PlaylistPageExercise \(passed ? "PASS" : "FAIL"): \(name)"
        if passed { MidgarLog.info(line, category: .general) } else { MidgarLog.error(line, category: .general) }
    }

    private static func finish(_ reason: String) {
        MidgarLog.error("PLAYLIST PAGE EXERCISE FAILED: \(reason)", category: .general)
    }

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private static func topController(of window: UIWindow?) -> UIViewController? {
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
#endif
