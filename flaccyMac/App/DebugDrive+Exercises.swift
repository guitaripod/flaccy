import MidgarCore
#if DEBUG
import AppKit
import FlaccyCore

extension DebugDrive {

    /// Drives the exact code paths behind the library UI — play from the
    /// grid, Play Next, Add to Queue, playlist create/add/reorder/remove and
    /// the drag-drop import — and logs each result for headless verification.
    static func exerciseLibrary(window: NSWindow?) async {
        AudioPlayer.shared.volume = 0.05
        var attempts = 0
        while Library.shared.albums.isEmpty, attempts < 40 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        let albums = Library.shared.albums
        guard albums.count >= 2, let first = albums.first, let second = albums.dropFirst().first else {
            MidgarLog.error("DebugDrive: need 2+ albums to exercise library", category: .general)
            return
        }

        AudioPlayer.shared.play(first.tracks, startingAt: 0)
        try? await Task.sleep(for: .seconds(1))
        MidgarLog.info(
            "DebugDrive: grid play — now \(AudioPlayer.shared.currentTrack?.title ?? "none"), queue \(AudioPlayer.shared.queue.count)",
            category: .general
        )

        if let next = second.tracks.first {
            AudioPlayer.shared.insertNext(next)
            MidgarLog.info("DebugDrive: Play Next inserted \(next.title), queue \(AudioPlayer.shared.queue.count)", category: .general)
        }
        if let queued = second.tracks.last {
            AudioPlayer.shared.addToQueue(queued)
            MidgarLog.info("DebugDrive: Add to Queue appended \(queued.title), queue \(AudioPlayer.shared.queue.count)", category: .general)
        }

        do {
            let playlist = try DatabaseManager.shared.createPlaylist(name: "DebugDrive Mix")
            guard let playlistId = playlist.id else { return }
            PlaylistActions.add(Array(first.tracks.prefix(3)), toPlaylist: playlistId, named: playlist.name, in: window)
            var records = try DatabaseManager.shared.fetchPlaylistTracks(playlistId: playlistId)
            MidgarLog.info("DebugDrive: playlist has \(records.count) rows", category: .general)
            records.reverse()
            PlaylistActions.persistOrder(records)
            let reordered = try DatabaseManager.shared.fetchPlaylistTracks(playlistId: playlistId)
            MidgarLog.info(
                "DebugDrive: reorder check — first row now \(reordered.first?.trackFileURL ?? "none")",
                category: .general
            )
            if let victim = reordered.first?.id {
                try DatabaseManager.shared.removeTrackFromPlaylist(id: victim)
                let remaining = try DatabaseManager.shared.fetchPlaylistTracks(playlistId: playlistId)
                MidgarLog.info("DebugDrive: row removed, \(remaining.count) remain", category: .general)
            }
            try DatabaseManager.shared.deletePlaylist(id: playlistId)
            MidgarLog.info("DebugDrive: playlist deleted", category: .general)
        } catch {
            MidgarLog.error("DebugDrive: playlist exercise failed: \(error.localizedDescription)", category: .general)
        }

        if let sourceTrack = second.tracks.first {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("DebugDriveImport", isDirectory: true)
            let stagedFile = staging.appendingPathComponent("Debug Drive Import.flac")
            do {
                try? FileManager.default.removeItem(at: staging)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: sourceTrack.fileURL, to: stagedFile)
                let before = Library.shared.allTracks.count
                await Library.shared.importFiles(from: [stagedFile]) { _ in }
                let after = Library.shared.allTracks.count
                MidgarLog.info("DebugDrive: drop import — tracks \(before) → \(after)", category: .general)
                try? FileManager.default.removeItem(at: staging)
            } catch {
                MidgarLog.error("DebugDrive: import exercise failed: \(error.localizedDescription)", category: .general)
            }
        }
        MidgarLog.info("DebugDrive: library exercise complete", category: .general)
    }

    /// Imports a staged compilation folder twice through the real importer and
    /// checks the tree it leaves: the folder keeps its name and both discs,
    /// lyrics travel, artwork and hidden files do not, no `.part` survives, and
    /// the second run copies nothing. The folder is removed again afterwards.
    static func exerciseFolderImport() async {
        var attempts = 0
        while Library.shared.allTracks.count < 2, attempts < 40 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        let tracks = Library.shared.allTracks.filter { $0.fileURL.pathExtension.lowercased() == "flac" }
        guard tracks.count >= 2 else {
            MidgarLog.error("DebugDrive: import exercise needs two FLAC tracks", category: .general)
            return
        }
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appendingPathComponent("DebugDriveFolder", isDirectory: true)
        let folderName = "Debug Drive Compilation"
        let folder = staging.appendingPathComponent(folderName, isDirectory: true)
        let imported = LibraryPaths.root.appendingPathComponent(folderName, isDirectory: true)
        do {
            try? fileManager.removeItem(at: staging)
            try? fileManager.removeItem(at: imported)
            try fileManager.createDirectory(at: folder.appendingPathComponent("CD1"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: folder.appendingPathComponent("CD2"), withIntermediateDirectories: true)
            try fileManager.copyItem(at: tracks[0].fileURL, to: folder.appendingPathComponent("CD1/01.flac"))
            try fileManager.copyItem(at: tracks[1].fileURL, to: folder.appendingPathComponent("CD2/01.flac"))
            try Data("[00:01.00]debug".utf8).write(to: folder.appendingPathComponent("CD1/01.lrc"))
            try Data([0xFF, 0xD8]).write(to: folder.appendingPathComponent("cover.jpg"))
            try Data([0]).write(to: folder.appendingPathComponent(".hidden.flac"))
        } catch {
            MidgarLog.error("DebugDrive: import staging failed: \(error.localizedDescription)", category: .general)
            return
        }

        let first = await Library.shared.importFiles(from: [folder]) { progress in
            MidgarLog.info("DebugDrive: import progress \(progress)", category: .general)
        }
        let second = await Library.shared.importFiles(from: [folder]) { _ in }
        let expectations: [(String, Bool)] = [
            ("first run imported 2, skipped 0, failed 0", first == LibraryImportOutcome(imported: 2, skipped: 0, failed: 0)),
            ("second run imported 0, skipped 2, failed 0", second == LibraryImportOutcome(imported: 0, skipped: 2, failed: 0)),
            ("CD1/01.flac kept its disc", fileManager.fileExists(atPath: imported.appendingPathComponent("CD1/01.flac").path)),
            ("CD2/01.flac kept its disc", fileManager.fileExists(atPath: imported.appendingPathComponent("CD2/01.flac").path)),
            ("lyrics travelled", fileManager.fileExists(atPath: imported.appendingPathComponent("CD1/01.lrc").path)),
            ("artwork stayed behind", !fileManager.fileExists(atPath: imported.appendingPathComponent("cover.jpg").path)),
            ("hidden file stayed behind", !fileManager.fileExists(atPath: imported.appendingPathComponent(".hidden.flac").path)),
            ("no second copy", !fileManager.fileExists(atPath: imported.appendingPathComponent("CD1/01_1.flac").path)),
            ("no staging left", !fileManager.fileExists(atPath: imported.appendingPathComponent("CD1/.01.flac.flaccy-part").path)),
            ("library indexed both", Library.shared.allTracks.filter { $0.fileURL.path.contains(folderName) }.count == 2),
        ]
        for (name, passed) in expectations {
            MidgarLog.info("DebugDrive: import \(passed ? "PASS" : "FAIL") — \(name)", category: .general)
        }
        MidgarLog.info("DebugDrive: import outcomes \(first) then \(second)", category: .general)
        try? fileManager.removeItem(at: imported)
        try? fileManager.removeItem(at: staging)
        await Library.shared.reload()
        let verdict = expectations.allSatisfy(\.1) ? "PASSED" : "FAILED"
        MidgarLog.info("DebugDrive: import exercise \(verdict)", category: .general)
    }

    static func exercise(window: NSWindow?) async {
        AudioPlayer.shared.volume = 0.05
        var attempts = 0
        while Library.shared.albums.isEmpty, attempts < 40 {
            try? await Task.sleep(for: .milliseconds(500))
            attempts += 1
        }
        guard let album = Library.shared.albums.first, !album.tracks.isEmpty else {
            MidgarLog.error("DebugDrive: no albums to exercise", category: .general)
            return
        }
        MidgarLog.info("DebugDrive: playing \(album.title) — \(album.artist)", category: .general)
        AudioPlayer.shared.play(album.tracks, startingAt: 0)

        try? await Task.sleep(for: .seconds(2))
        MidgarLog.info("DebugDrive: seek to 20s (playing: \(AudioPlayer.shared.isPlaying))", category: .general)
        AudioPlayer.shared.seek(to: 20)

        try? await Task.sleep(for: .seconds(1))
        MidgarLog.info("DebugDrive: pause", category: .general)
        AudioPlayer.shared.togglePlayPause()

        try? await Task.sleep(for: .seconds(1))
        MidgarLog.info("DebugDrive: resume", category: .general)
        AudioPlayer.shared.togglePlayPause()

        try? await Task.sleep(for: .seconds(1))
        MidgarLog.info("DebugDrive: next track", category: .general)
        AudioPlayer.shared.nextTrack()

        try? await Task.sleep(for: .seconds(1))
        if let window {
            let frame = window.frame
            window.setFrame(
                NSRect(x: frame.minX, y: frame.minY, width: frame.width + 80, height: frame.height + 40),
                display: true, animate: false
            )
            try? await Task.sleep(for: .milliseconds(500))
            window.setFrame(frame, display: true, animate: false)
        }
        MidgarLog.info(
            "DebugDrive: exercise complete (playing: \(AudioPlayer.shared.isPlaying), track: \(AudioPlayer.shared.currentTrack?.title ?? "none"), time: \(AudioPlayer.shared.currentTime))",
            category: .general
        )
    }
}
#endif
