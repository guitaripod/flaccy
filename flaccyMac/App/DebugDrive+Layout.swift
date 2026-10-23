import MidgarCore
#if DEBUG
import AppKit
import FlaccyCore

extension DebugDrive {

    /// Applies the `--detail-*` arguments to the album or playlist page that is
    /// on screen: a filter, a table sort, a song playing from the page, a jump
    /// to the playing song and a timing of every layout switch.
    static func driveDetailPage(window: NSWindow?) async {
        try? await Task.sleep(for: .seconds(2))
        let root = window?.contentViewController
        let album: AlbumDetailViewController? = findController(in: root)
        let playlist: PlaylistDetailViewController? = findController(in: root)
        guard let songs = album?.debugSongs ?? playlist?.debugSongs else {
            MidgarLog.error("DebugDrive: no song page on screen", category: .general)
            return
        }
        if let index = value(after: "--detail-play").flatMap(Int.init), songs.model.entries.indices.contains(index) {
            AudioPlayer.shared.volume = 0.02
            AudioPlayer.shared.play(songs.model.entries.map(\.track), startingAt: index)
            try? await Task.sleep(for: .seconds(1))
        }
        if let text = value(after: "--detail-filter") {
            songs.debugFilter(text)
            try? await Task.sleep(for: .seconds(1))
        }
        if let sort = value(after: "--detail-sort") {
            let parts = sort.split(separator: ":").map(String.init)
            songs.debugSort(column: parts[0], ascending: parts.count < 2 || parts[1] != "desc")
            try? await Task.sleep(for: .seconds(1))
        }
        if CommandLine.arguments.contains("--detail-exercise-layouts") {
            await exerciseLayoutSwitching(songs)
        }
        if CommandLine.arguments.contains("--detail-exercise-playlist") {
            await exercisePlaylistEditing(songs)
        }
        if CommandLine.arguments.contains("--detail-bench") {
            await benchmarkLayouts(songs, window: window)
        }
        if CommandLine.arguments.contains("--detail-locate") {
            window?.contentView?.layoutSubtreeIfNeeded()
            songs.locatePlaying()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Switches layouts through the segmented control's own action and logs
    /// whether the choice is remembered, shared across kinds, resolved for a
    /// playlist without being overwritten, and snaps the page to the top.
    static func exerciseLayoutSwitching(_ songs: TrackPageSongs) async {
        func report(_ expectation: String, _ passed: Bool) {
            MidgarLog.info("DetailExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .general)
        }
        let key = TrackPageSongs.layoutKey
        for layout in TrackPageLayout.Layout.allCases where layout.isOffered(on: songs.model.kind) {
            let changes = songs.layout != layout
            songs.debugScroll(to: 300)
            try? await Task.sleep(for: .milliseconds(300))
            songs.debugPick(layout)
            try? await Task.sleep(for: .milliseconds(600))
            report("picking \(layout.id) stores it (stored \(UserDefaults.standard.string(forKey: key) ?? "nil"))",
                   UserDefaults.standard.string(forKey: key) == layout.id && songs.layout == layout)
            report("picking \(layout.id) \(changes ? "scrolls to the top" : "again leaves the page alone") (offset \(songs.debugScrollOffset ?? -1))",
                   changes ? abs(songs.debugScrollOffset ?? -1) < 1 : (songs.debugScrollOffset ?? 0) > 1)
        }
        UserDefaults.standard.set("columns", forKey: key)
        let resolved = TrackPageSongs.savedLayout(for: .playlist)
        report("a remembered columns resolves to list for a playlist (got \(resolved.id)) and stays stored",
               resolved == .list && UserDefaults.standard.string(forKey: key) == "columns")
        report("a remembered columns stays columns for an album",
               TrackPageSongs.savedLayout(for: .album) == .columns)
    }

    /// Reorders and removes rows through the same closures a drag and the
    /// context menu call, then reads the page back from the database it
    /// reloads from, and logs PASS or FAIL for each.
    static func exercisePlaylistEditing(_ songs: TrackPageSongs) async {
        func titles() -> [String] { songs.model.entries.prefix(4).map(\.track.title) }
        func report(_ expectation: String, _ passed: Bool) {
            MidgarLog.info("DetailExercise \(passed ? "PASS" : "FAIL"): \(expectation)", category: .general)
        }
        let before = titles()
        let count = songs.model.entries.count
        songs.model.reorder?(IndexSet(integer: 0), 3)
        try? await Task.sleep(for: .seconds(1))
        let expected = [before[1], before[2], before[0], before[3]]
        report("moving row 1 below row 3 gives \(expected) (got \(titles()))", titles() == expected)
        songs.model.reorder?(IndexSet([1, 2]), 0)
        try? await Task.sleep(for: .seconds(1))
        let both = [expected[1], expected[2], expected[0], expected[3]]
        report("moving rows 2 and 3 to the top gives \(both) (got \(titles()))", titles() == both)
        if let first = songs.model.entries.first {
            songs.model.remove?([first])
            try? await Task.sleep(for: .seconds(1))
            report("removing the first row leaves \(count - 1) rows (got \(songs.model.entries.count))",
                   songs.model.entries.count == count - 1 && songs.model.entries.first?.track.title == both[1])
        }
    }

    static func benchmarkLayouts(_ songs: TrackPageSongs, window: NSWindow?) async {
        func milliseconds(_ label: String, _ work: () -> Void) {
            let start = CFAbsoluteTimeGetCurrent()
            work()
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.contentView?.displayIfNeeded()
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            MidgarLog.info("DebugDrive: \(label) took \(elapsed) ms for \(songs.model.entries.count) songs", category: .general)
        }
        for layout in TrackPageLayout.Layout.allCases where layout.isOffered(on: songs.model.kind) {
            milliseconds("layout \(layout.id)") { songs.debugChoose(layout) }
            milliseconds("filter on \(layout.id)") { songs.debugFilter("song 99") }
            milliseconds("filter cleared on \(layout.id)") { songs.debugFilter("") }
        }
        milliseconds("sort by title") { songs.debugChoose(.table); songs.debugSort(column: "title", ascending: false) }
    }

    /// Section switches can shrink the window below the requested capture
    /// size; re-apply the `--window-size` content size right before capture.
    static func reassertWindowSizeIfRequested(_ window: NSWindow?) {
        guard let window,
              let index = CommandLine.arguments.firstIndex(of: "--window-size"),
              index + 1 < CommandLine.arguments.count else { return }
        let parts = CommandLine.arguments[index + 1].lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { return }
        window.setContentSize(NSSize(width: width, height: height))
    }
}
#endif
