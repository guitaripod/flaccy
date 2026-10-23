import MidgarCore
#if DEBUG
import AppKit
import FlaccyCore

extension DebugDrive {

    /// Seeds two populated playlists from the fictional catalog so the
    /// Playlists screenshot never renders an empty state. Idempotent.
    static func seedDemoPlaylists() {
        let plans: [(name: String, picks: [(String, Int)])] = [
            ("Night Drive", [("Parallax Hours", 1), ("Signal Bloom", 3), ("Cassini", 0),
                             ("Midnatt", 0), ("Aurorae", 1), ("Paper Cities", 0), ("Almagest", 0), ("Nightglow", 1)]),
            ("Sunday Slow", [("Tradewinds", 0), ("Ember & Ash", 4), ("Lantern Year", 1),
                             ("Ravine", 1), ("Aurorae", 4), ("Ledger of Small Hours", 3), ("Saltwater Gospel", 4)]),
            ("Deep Focus", [("Tidal Glass", 0), ("Overwinter", 0), ("Field Lines", 0), ("Vantablack Sun", 2),
                            ("Aurorae", 2), ("Midnatt", 1)]),
            ("Golden Hour", [("Greenhouse Hymns", 0), ("Velvet Arithmetic", 0), ("Cassini", 1),
                             ("Saltwater Gospel", 0), ("Paper Cities", 1), ("Southern Cross", 0)]),
            ("Lossless Showcase", [("Parallax Hours", 5), ("Field Lines", 3), ("Vantablack Sun", 0),
                                   ("Southern Cross", 2), ("Almagest", 3), ("Tidal Glass", 2)]),
            ("Rainy Windows", [("Radio Silence", 0), ("Statuary", 1), ("Longshore Drift", 0),
                               ("Ember & Ash", 2), ("Paper Cities", 4)]),
            ("Late Shift", [("Signal Bloom", 0), ("Nightglow", 0), ("Almagest", 2), ("Field Lines", 3),
                            ("Midnatt", 3)]),
        ]
        do {
            let existing = try DatabaseManager.shared.fetchAllPlaylists().map(\.name)
            for plan in plans where !existing.contains(plan.name) {
                let playlist = try DatabaseManager.shared.createPlaylist(name: plan.name)
                guard let playlistId = playlist.id else { continue }
                let tracks = plan.picks.compactMap { title, index -> Track? in
                    guard let album = Library.shared.albums.first(where: { $0.title == title }),
                          album.tracks.indices.contains(index) else { return nil }
                    return album.tracks[index]
                }
                PlaylistActions.add(tracks, toPlaylist: playlistId, named: plan.name, in: nil)
            }
        } catch {
            MidgarLog.error("DebugDrive: playlist seeding failed: \(error.localizedDescription)", category: .general)
        }
    }

    /// Pops mid-push at varying offsets inside the 240ms slide animation to
    /// prove overlapping transitions can never leave the section root hidden.
    static func exerciseStack(window: NSWindow?) async {
        var attempts = 0
        while Library.shared.albums.isEmpty, attempts < 40 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        try? await Task.sleep(for: .seconds(1))
        guard let album = Library.shared.albums.first else {
            MidgarLog.error("DebugDrive: no album for stack exercise", category: .general)
            return
        }
        for delayMs in [20, 60, 120, 180, 230, 300] {
            LibraryNavigator.revealAlbum(title: album.title, artist: album.artist)
            try? await Task.sleep(for: .milliseconds(delayMs))
            findStack(window: window)?.pop()
            try? await Task.sleep(for: .milliseconds(delayMs))
        }
        LibraryNavigator.revealAlbum(title: album.title, artist: album.artist)
        try? await Task.sleep(for: .milliseconds(100))
        findStack(window: window)?.popToRoot()
        try? await Task.sleep(for: .seconds(1))
        guard let stack = findStack(window: window), let root = stack.stack.first else {
            MidgarLog.error("DebugDrive: stack exercise found no ContentStackController", category: .general)
            return
        }
        MidgarLog.info(
            "DebugDrive: stack exercise complete — depth \(stack.stack.count), rootHidden=\(root.view.isHidden), rootAlpha=\(root.view.alphaValue)",
            category: .general
        )
    }

    /// Drives the Songs table the way a person would: pivots to a chip that
    /// hides the playing song, asks to jump to it (once with a search also
    /// hiding it), and saves the visible list as a playlist, logging PASS or
    /// FAIL for each expectation.
    static func exerciseSongs(window: NSWindow?) async {
        let resultsURL = URL(fileURLWithPath: NSTemporaryDirectory() + "songs-exercise.txt")
        try? "".write(to: resultsURL, atomically: true, encoding: .utf8)
        func report(_ expectation: String, _ passed: Bool) {
            let line = "SongsExercise \(passed ? "PASS" : "FAIL"): \(expectation)"
            MidgarLog.info(line, category: .general)
            let existing = (try? String(contentsOf: resultsURL, encoding: .utf8)) ?? ""
            try? (existing + line + "\n").write(to: resultsURL, atomically: true, encoding: .utf8)
        }
        var attempts = 0
        while Library.shared.albums.isEmpty, attempts < 40 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        await seedRecentListeningIfRequested()
        startHeroPlayback()
        try? await Task.sleep(for: .seconds(2))
        guard let playing = AudioPlayer.shared.currentTrack?.fileURL.path else {
            report("a song is playing", false)
            return
        }
        NotificationCenter.default.post(
            name: .flaccyShowSection, object: nil,
            userInfo: [SectionNotificationKey.section: SidebarSection.songs.rawValue]
        )
        try? await Task.sleep(for: .seconds(3))
        guard let songs: SongsTableViewController = findController(in: window?.contentViewController) else {
            report("the songs table is on screen", false)
            return
        }
        let pivots: [(SongsTableViewModel.Filter, ChartPeriod?)] = [
            (.favorites, nil), (.rediscover, nil), (.mostPlayed, .week), (.recentlyPlayed, nil), (.lossless, nil),
        ]
        var hidden = false
        for (filter, range) in pivots {
            songs.selectFilterForCapture(filter, range: range)
            try? await Task.sleep(for: .seconds(1))
            if !songs.visibleTrackPathsForExercise.contains(playing) {
                hidden = true
                break
            }
        }
        report("a chip hides the playing song (\(songs.filterForExercise.rawValue))", hidden)

        (NSApp.delegate as? MacAppDelegate)?.jumpToCurrentSong(nil)
        try? await Task.sleep(for: .seconds(2))
        report("jump switches the chip to All", songs.filterForExercise == .all)
        report("jump selects the playing song's row", songs.selectedTrackPathForExercise == playing)

        LibrarySearchState.update("zzzz-no-such-song")
        try? await Task.sleep(for: .seconds(1))
        report("a search that matches nothing empties the list", songs.visibleTrackPathsForExercise.isEmpty)
        (NSApp.delegate as? MacAppDelegate)?.jumpToCurrentSong(nil)
        try? await Task.sleep(for: .seconds(2))
        report("jump clears the search that hid the song", LibrarySearchState.query.isEmpty)
        report("jump selects the row after clearing the search", songs.selectedTrackPathForExercise == playing)

        songs.selectFilterForCapture(.recentlyAdded, range: nil)
        try? await Task.sleep(for: .seconds(1))
        let visible = songs.visibleTrackPathsForExercise
        let tracks = Library.shared.allTracks
        let ordered = visible.compactMap { path in tracks.first { $0.fileURL.path == path } }
        if let playlist = try? DatabaseManager.shared.createPlaylist(name: "Exercise \(UUID().uuidString.prefix(6))"),
           let id = playlist.id {
            PlaylistActions.add(ordered, toPlaylist: id, named: playlist.name, in: nil)
            let saved = (try? DatabaseManager.shared.fetchPlaylistTracks(playlistId: id)) ?? []
            let savedPaths = saved.sorted { $0.position < $1.position }.map(\.trackFileURL)
            let expected = ordered.map { LibraryPathResolver.relativePath(for: $0.fileURL) }
            report("saving \(ordered.count) visible songs keeps their order", savedPaths == expected && !expected.isEmpty)
        } else {
            report("a playlist can be created", false)
        }
        report("status line reads \(songs.statusLineForExercise)", !songs.statusLineForExercise.isEmpty)
        report("done", true)
    }

    static func seedRecentListeningIfRequested() async {
        guard DebugStatsDrive.wantsRecentListening else { return }
        await DebugStatsDrive.seedRecentListening()
    }

    static func findController<T: NSViewController>(in root: NSViewController?) -> T? {
        guard let root else { return nil }
        if let match = root as? T { return match }
        for child in root.children {
            if let match: T = findController(in: child) { return match }
        }
        return nil
    }

    static func findStack(window: NSWindow?) -> ContentStackController? {
        guard let root = window?.contentViewController else { return nil }
        return descendToStack(root)
    }

    static func descendToStack(_ controller: NSViewController) -> ContentStackController? {
        if let stack = controller as? ContentStackController { return stack }
        for child in controller.children {
            if let stack = descendToStack(child) { return stack }
        }
        return nil
    }
}
#endif
