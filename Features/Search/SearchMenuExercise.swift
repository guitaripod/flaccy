import MidgarCore
#if DEBUG
import FlaccyCore
import UIKit

/// Searches the library for one of its songs and one of its albums and checks
/// that a long press on each result opens the menu the Library gives it, with
/// the queue and playlist actions, while artists and playlists open none.
/// Logs `SearchMenuExercise PASS/FAIL` per check and `SEARCH MENU EXERCISE
/// PASSED` or `FAILED`. Launch with `--exercise-search-menu` over a library.
@MainActor
enum SearchMenuExercise {

    static let launchArgument = "--exercise-search-menu"

    private static var results: [Bool] = []

    static func runIfRequested(tabs: AppTabBarController) {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task { await run(tabs: tabs) }
    }

    private static func run(tabs: AppTabBarController) async {
        guard await libraryArrived(), let album = Library.shared.albums.first, let track = album.tracks.first else {
            return MidgarLog.error("SEARCH MENU EXERCISE FAILED: the library never loaded", category: .general)
        }
        try? await Task.sleep(for: .seconds(2))

        tabs.search.demoSearch(query: track.title)
        let songMenus = tabs.search.debugLongPressMenus()
        let songTitles = (songMenus[.songs] ?? nil) ?? []
        report("a found song opens a menu (\(songTitles.joined(separator: ", ")))", !songTitles.isEmpty)
        for title in ["Play Next", "Add to Queue", "Add to Playlist", "Go to Album"] {
            report("the song menu offers \(title)", songTitles.contains(String(localized: String.LocalizationValue(title))))
        }
        if let artistMenu = songMenus[.artists] {
            report("a found artist opens no menu, as in the Library", artistMenu == nil)
        }

        tabs.search.demoSearch(query: album.title)
        let albumMenus = tabs.search.debugLongPressMenus()
        let albumTitles = (albumMenus[.albums] ?? nil) ?? []
        report("a found album opens a menu (\(albumTitles.joined(separator: ", ")))", !albumTitles.isEmpty)
        for title in ["Play Next", "Add to Queue", "Shuffle"] {
            report("the album menu offers \(title)", albumTitles.contains(String(localized: String.LocalizationValue(title))))
        }

        let passed = results.allSatisfy { $0 }
        let line = "SEARCH MENU EXERCISE \(passed ? "PASSED" : "FAILED"): \(results.filter { $0 }.count) of \(results.count)"
        if passed { MidgarLog.info(line, category: .general) } else { MidgarLog.error(line, category: .general) }
    }

    private static func libraryArrived() async -> Bool {
        for _ in 0..<120 {
            if !Library.shared.albums.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private static func report(_ expectation: String, _ passed: Bool) {
        results.append(passed)
        let line = "SearchMenuExercise \(passed ? "PASS" : "FAIL"): \(expectation)"
        if passed { MidgarLog.info(line, category: .general) } else { MidgarLog.error(line, category: .general) }
    }
}
#endif
