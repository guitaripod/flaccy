#if DEBUG
import AppKit
import FlaccyCore
import FlaccyEngine
import Foundation
import MidgarCore

/// Proves the move between the two Mac apps end to end and logs `HANDOFF EXERCISE PASSED` or
/// `HANDOFF EXERCISE FAILED: <step>`. Launch both builds with `--exercise-handoff --handoff-container <folder>`,
/// each with its own `CFFIXED_USER_HOME`, and `--handoff-library-folder <folder>` for the music folder. The legacy
/// build seeds a small library in that folder, exports it and checks the export. The universal build, started after
/// it, must have imported the library before the first window: it checks the rows, the defaults, that the folder is
/// asked for again while the library stays offline, and that choosing the same folder keeps every song.
@MainActor
enum HandoffExercise {

    private static let marker = "flaccy.handoffExercise.marker"
    private static let markerValue = 42
    private static let playlistName = "Handoff Exercise Playlist"
    private static let songPaths = ["Reexport Exercise/Rough Mix.wav", "Reexport Exercise/Other Take.wav"]
    private static let playCount = 9

    private struct Failure: Error {
        let step: String
    }

    static func runIfRequested(window: NSWindow?) {
        guard CommandLine.arguments.contains("--exercise-handoff") else { return }
        Task {
            do {
                #if LEGACY_MAC_HANDOFF
                try await runLegacy()
                #else
                try await runUniversal()
                #endif
            } catch let failure as Failure {
                MidgarLog.error("HANDOFF EXERCISE FAILED: \(failure.step)", category: .general)
            } catch {
                MidgarLog.error("HANDOFF EXERCISE FAILED: \(error.localizedDescription)", category: .general)
            }
        }
    }

    #if LEGACY_MAC_HANDOFF
    private static func runLegacy() async throws {
        let folder = try require(libraryFolder, "--handoff-library-folder names the music folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try LibraryRoot.shared.chooseFolder(folder)
        try await Task.sleep(for: .seconds(2))
        let seeded = await ReexportExercise.seedRevisedSong()
        _ = try require(seeded, "the legacy library holds the seeded songs")
        let database = DatabaseManager.shared
        for path in songPaths {
            _ = try require(try database.fetchTrack(byRelativePath: path), "the legacy database indexed \(path)")
        }
        let playlist = try database.createPlaylist(name: playlistName)
        try database.addTracksToPlaylist(playlistId: try require(playlist.id, "the playlist has an id"), trackFileURLs: songPaths)
        try database.setPlayCount(relativePath: songPaths[0], count: playCount)
        UserDefaults.standard.set(markerValue, forKey: marker)
        report("the legacy library is seeded with \(songPaths.count) songs, a playlist and a default")

        let manifest = try LegacyMacHandoff.exportLibrary()
        let container = try require(HandoffContainer.url, "the export container resolves")
        let exportedFolder = manifest.libraryFolderPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        try check(exportedFolder == folder.resolvingSymlinksInPath().path, "the manifest names the music folder (\(manifest.libraryFolderPath ?? "nil"))")
        let exported = container
            .appendingPathComponent("\(LibraryHandoff.folderName)/\(LibraryHandoff.dataFolderPath)/\(LibraryHandoff.databaseName)")
        let copy = try DatabaseManager(path: exported.path)
        let copiedPaths = try copy.fetchAllTrackRelativePaths()
        try check(Set(songPaths).isSubset(of: copiedPaths), "the exported database holds the seeded songs (\(copiedPaths.count) rows)")
        try check(try copy.fetchAllPlaylists().contains { $0.name == playlistName }, "the exported database holds the playlist")
        try check(try copy.fetchTrack(byRelativePath: songPaths[0])?.playCount == playCount, "the exported database keeps the play count")
        let defaults = try require(
            NSDictionary(contentsOf: container.appendingPathComponent("\(LibraryHandoff.folderName)/\(LibraryHandoff.defaultsName)")) as? [String: Any],
            "the export carries the defaults"
        )
        try check(defaults[marker] as? Int == markerValue, "the export carries the exercise default")
        try check(defaults[LibraryRoot.bookmarkKey] != nil, "the export carries the folder bookmark for the old app")
        MidgarLog.info("HANDOFF EXERCISE EXPORTED: \(copiedPaths.count) rows, folder \(manifest.libraryFolderPath ?? "none")", category: .general)
    }
    #else
    private static func runUniversal() async throws {
        let folder = try require(libraryFolder, "--handoff-library-folder names the music folder")
        let container = try require(HandoffContainer.url, "the export container resolves")
        let manifest = try require(LibraryHandoff.manifest(in: container), "the export is still in place after the import")
        try await waitForLibrary()

        let database = DatabaseManager.shared
        for path in songPaths {
            _ = try require(try database.fetchTrack(byRelativePath: path), "the imported database holds \(path)")
        }
        let playlist = try require(try database.fetchAllPlaylists().first { $0.name == playlistName }, "the playlist arrived")
        let playlistTracks = try database.fetchPlaylistTracks(playlistId: try require(playlist.id, "the playlist has an id"))
        try check(playlistTracks.map(\.trackFileURL) == songPaths, "the playlist kept its songs in order")
        try check(try database.fetchTrack(byRelativePath: songPaths[0])?.playCount == playCount, "the play count arrived")
        try check(UserDefaults.standard.integer(forKey: marker) == markerValue, "the exported default was applied")

        try check(HandoffFolderPrompt.pendingPath == manifest.libraryFolderPath, "the exported folder is waiting to be chosen again")
        try check(UserDefaults.standard.data(forKey: LibraryRoot.bookmarkKey) == nil, "the old app's folder bookmark was not applied")
        try check(LibraryRoot.shared.isFallbackActive, "the library is offline until the folder is chosen")
        try check(OnboardingPanelView.visibility == .show, "the welcome panel is up asking for the folder")
        try check(HandoffFolderPrompt.suggestedFolder?.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path, "the open panel starts in the old folder")
        try check(Library.shared.allTracks.count >= songPaths.count, "the offline library still lists its songs (\(Library.shared.allTracks.count))")
        let rowsBefore = try database.fetchAllTrackRelativePaths()

        try LibraryRoot.shared.chooseFolder(folder)
        try await Task.sleep(for: .seconds(2))
        await Library.shared.reload()
        let rowsAfter = try database.fetchAllTrackRelativePaths()
        try check(rowsAfter == rowsBefore, "choosing the same folder keeps every song (\(rowsAfter.count) rows)")
        try check(try database.fetchTrack(byRelativePath: songPaths[0])?.playCount == playCount, "choosing the folder keeps the play count")
        try check(try database.fetchPlaylistTracks(playlistId: try require(playlist.id, "the playlist has an id")).count == songPaths.count, "choosing the folder keeps the playlist")
        try check(!HandoffFolderPrompt.isPending && !LibraryRoot.shared.isFallbackActive, "the library is back online")
        try check(OnboardingPanelView.visibility == .hide, "the welcome panel is gone")
        try check(LibraryHandoff.manifest(in: container) != nil, "the export is left in place")
        MidgarLog.info("HANDOFF EXERCISE PASSED", category: .general)
    }

    private static func waitForLibrary() async throws {
        try await Task.sleep(for: .seconds(3))
        for _ in 0..<120 where Library.shared.isLoading {
            try await Task.sleep(for: .milliseconds(500))
        }
    }
    #endif

    private static var libraryFolder: URL? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--handoff-library-folder"), arguments.indices.contains(flag + 1)
        else { return nil }
        return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    }

    private static func check(_ condition: Bool, _ step: String) throws {
        report(step, passed: condition)
        guard condition else { throw Failure(step: step) }
    }

    private static func require<Value>(_ value: Value?, _ step: String) throws -> Value {
        report(step, passed: value != nil)
        guard let value else { throw Failure(step: step) }
        return value
    }

    private static func report(_ step: String, passed: Bool = true) {
        MidgarLog.info("HandoffExercise \(passed ? "PASS" : "FAIL"): \(step)", category: .general)
    }
}
#endif
