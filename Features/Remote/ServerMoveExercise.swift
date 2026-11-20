#if DEBUG
import FlaccyCore
import FlaccyEngine
import Foundation
import MidgarCore

/// Drives moving songs on this device to a Flaccy Server end to end and logs `SERVER MOVE EXERCISE PASSED` or
/// `SERVER MOVE EXERCISE FAILED: <step>`. Launch with `--exercise-server-move` and `FLACCY_EXERCISE_SERVER=<flaccy://server link>`
/// on a simulator whose Documents hold `MoveExercise/`: AAC copies of three of the server's songs with the server's tags, a second
/// copy of the first in `MoveExercise/Copy/`, and `MoveExercise/Only Here.m4a`, a song the server does not have.
///
/// It connects through the real setup path, lets the first sync list the server's songs, loves the first song, plays the second
/// once and puts the first, the second and the second copy in a playlist, then checks the offer (three songs, one further copy,
/// one loved, one staying), moves with loved songs kept, and checks that the rows kept their ids, love, play and playlist places,
/// the loved song's file became its download, the others' files and the emptied copy folder are gone, the song that stays is
/// still a song of this device, a rescan adds nothing back, and the second song plays from the server.
@MainActor
enum ServerMoveExercise {

    static let launchArgument = "--exercise-server-move"

    private struct Failure: Error {
        let step: String
    }

    static let crashArgument = "--exercise-server-move-crash"
    static let recoverArgument = "--exercise-server-move-recover"

    static func runIfRequested() {
        if CommandLine.arguments.contains(crashArgument) { return runStep("CRASH", stageCrash) }
        if CommandLine.arguments.contains(recoverArgument) { return runStep("RECOVERY", checkRecovery) }
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task {
            do {
                try await run()
                MidgarLog.info("SERVER MOVE EXERCISE PASSED", category: .content)
            } catch let failure as Failure {
                MidgarLog.error("SERVER MOVE EXERCISE FAILED: \(failure.step)", category: .content)
            } catch {
                MidgarLog.error("SERVER MOVE EXERCISE FAILED: \(error.localizedDescription)", category: .content)
            }
        }
    }

    private static func run() async throws {
        let database = DatabaseManager.shared
        let text = ProcessInfo.processInfo.environment[ServerSyncExercise.environmentKey] ?? ""
        let link = try require(FlaccyServerLink(text: text), "\(ServerSyncExercise.environmentKey) holds a flaccy://server link")
        try await waitFor("the library lists the songs in MoveExercise") {
            Library.shared.allTracks.filter { LibraryPaths.relativePath(of: $0.fileURL).hasPrefix("MoveExercise/") }.count == 5
        }
        let local = Library.shared.allTracks.filter { LibraryPaths.relativePath(of: $0.fileURL).hasPrefix("MoveExercise/") }
        let copy = try require(local.first { LibraryPaths.relativePath(of: $0.fileURL).hasPrefix("MoveExercise/Copy/") }, "the second copy is listed")
        let only = try require(local.first { LibraryPaths.relativePath(of: $0.fileURL) == "MoveExercise/Only Here.m4a" }, "the song that stays is listed")
        let songs = local.filter { $0.fileURL != copy.fileURL && $0.fileURL != only.fileURL }.sorted { $0.trackNumber < $1.trackNumber }
        try expect(songs.count == 3, "three songs the server has are listed (\(songs.count))")
        let paths = songs.map { LibraryPaths.relativePath(of: $0.fileURL) }
        let copyPath = LibraryPaths.relativePath(of: copy.fileURL)
        let ids = try paths.map { try require(try database.fetchTrack(byRelativePath: $0)?.id, "\($0) has a row") }
        try database.setLoved(fileURL: paths[0], loved: true, pendingOp: nil)
        try database.incrementPlayCount(trackId: ids[1])
        let playlist = try database.createPlaylist(name: "Move Exercise")
        let playlistID = try require(playlist.id, "the playlist has an id")
        try database.addTracksToPlaylist(playlistId: playlistID, trackFileURLs: [paths[0], paths[1], copyPath])
        step("seeded: \(paths.joined(separator: ", ")), a copy and a song only here")

        let connection = try await FlaccyServerSetupGateway().connect(link: link, deviceName: "Move Exercise")
        try expect(await FlaccyServerSetupFollowUp().finish(connection), "the server's music joined the library")
        let record = try require(FlaccyServerLibrary.record(), "the server has a library row")
        try await RemoteCatalogSync.shared.sync(serverID: record.id)
        step("connected to \(connection.serverName) and listed \(try database.fetchRemoteTrackPaths(serverID: record.id).count) songs")

        let offer = try await ServerMoveService.offer(serverID: record.id, name: record.name)
        step("offer: \(offer.songs) songs, \(offer.duplicates.count) further copies, \(offer.lovedSongs) loved, \(offer.staying) staying, \(offer.bytes) bytes")
        try expect(offer.songs == 3, "the offer has the three songs (\(offer.songs))")
        try expect(offer.duplicates.map(\.local) == [copyPath], "the second copy folds into its song")
        try expect(offer.lovedSongs == 1, "one loved song")
        try expect(offer.staying == 1, "one song stays")
        let pairs = Dictionary(uniqueKeysWithValues: offer.pairs.map { ($0.local, $0.server) })
        let remote = try paths.map { try require(pairs[$0], "\($0) pairs with a server song") }
        try expect(offer.duplicates.first?.server == remote[0], "the copy folds into the first song")

        guard let summary = await ServerMoveService.shared.start(offer, choice: .stream(keepLoved: true)) else {
            throw Failure(step: "the move finished (\(ServerMoveService.shared.phase(for: record.id)))")
        }
        step("moved: \(summary.moved) songs, \(summary.kept) kept, \(summary.freedBytes) bytes freed, \(summary.notKept) not kept")
        try expect(summary.moved == 3 && summary.kept == 1 && summary.notKept == 0, "the summary counts three moved and one kept")

        for (index, path) in remote.enumerated() {
            let row = try require(try database.fetchTrack(byRelativePath: path), "\(path) has a row")
            try expect(row.id == ids[index], "\(paths[index]) kept its row id")
            try expect(try database.fetchTrack(byRelativePath: paths[index]) == nil, "\(paths[index]) no longer has a row of its own")
        }
        try expect(try database.fetchTrack(byRelativePath: copyPath) == nil, "the copy's row folded away")
        try expect(try database.fetchTrack(byRelativePath: remote[0])?.loved == true, "the first song is still loved")
        try expect((try database.fetchTrack(byRelativePath: remote[1])?.playCount ?? 0) >= 1, "the second song kept its play")
        let places = try database.fetchPlaylistTracks(playlistId: playlistID).map(\.trackFileURL)
        try expect(places == [remote[0], remote[1], remote[0]], "the playlist holds the server songs in order (\(places))")

        let first = try require(RemoteTrackPath(path: remote[0]), "the first song has a server path")
        let kept = try require(RemoteStreamCache.shared.completeFileURL(for: first), "the loved song's file is its download")
        try expect(kept.pathExtension == "m4a", "the kept download is this device's AAC file")
        try expect(try database.fetchTrack(byRelativePath: remote[0])?.pinned == true, "the loved song is downloaded")
        for path in paths + [copyPath] {
            try expect(!FileManager.default.fileExists(atPath: LibraryPaths.root.appendingPathComponent(path).path), "\(path) left the library folder")
        }
        try expect(!FileManager.default.fileExists(atPath: LibraryPaths.root.appendingPathComponent("MoveExercise/Copy").path), "the emptied copy folder is gone")
        try expect(FileManager.default.fileExists(atPath: only.fileURL.path), "the song that stays keeps its file")
        try expect(try database.pendingServerMoves().isEmpty, "no file waits to leave")

        await Library.shared.reload()
        let after = Library.shared.allTracks.filter { $0.fileURL.isFileURL && LibraryPaths.relativePath(of: $0.fileURL).hasPrefix("MoveExercise/") }
        try expect(after.map { LibraryPaths.relativePath(of: $0.fileURL) } == ["MoveExercise/Only Here.m4a"], "a rescan lists only the song that stays")

        let second = try require(Library.shared.allTracks.first { $0.remoteSong?.path == remote[1] }, "the second song is in the library")
        try expect(RemoteStreamCache.shared.completeFileURL(for: try require(second.remoteSong, "a server song")) == nil, "the second song streams")
        AudioPlayer.shared.play([second], startingAt: 0)
        try await Task.sleep(for: .seconds(4))
        let position = AudioPlayer.shared.currentTime
        AudioPlayer.shared.togglePlayPause()
        try expect(position > 1.5, "the second song plays from the server (\(position) s)")
        step("the second song played \(position) s from the server")
    }

    private static func runStep(_ name: String, _ body: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await body()
                MidgarLog.info("SERVER MOVE \(name) PASSED", category: .content)
            } catch let failure as Failure {
                MidgarLog.error("SERVER MOVE \(name) FAILED: \(failure.step)", category: .content)
            } catch {
                MidgarLog.error("SERVER MOVE \(name) FAILED: \(error.localizedDescription)", category: .content)
            }
        }
    }

    /// The first half of the crash drill (`--exercise-server-move-crash`): connects, lets the database step move every song
    /// the server has, and quits before a single file is touched, as a crash at that moment would.
    private static func stageCrash() async throws {
        let text = ProcessInfo.processInfo.environment[ServerSyncExercise.environmentKey] ?? ""
        let link = try require(FlaccyServerLink(text: text), "\(ServerSyncExercise.environmentKey) holds a flaccy://server link")
        try await waitFor("the library lists the songs in MoveExercise") {
            Library.shared.allTracks.filter { LibraryPaths.relativePath(of: $0.fileURL).hasPrefix("MoveExercise/") }.count == 5
        }
        let connection = try await FlaccyServerSetupGateway().connect(link: link, deviceName: "Move Crash")
        try expect(await FlaccyServerSetupFollowUp().finish(connection), "the server's music joined the library")
        let record = try require(FlaccyServerLibrary.record(), "the server has a library row")
        try await RemoteCatalogSync.shared.sync(serverID: record.id)
        let offer = try await ServerMoveService.offer(serverID: record.id, name: record.name)
        let records = try DatabaseManager.shared.applyServerMove(offer.steps(for: .stream(keepLoved: false)), now: Date())
        try expect(records.count == 4, "the database step journaled four files (\(records.count))")
        try expect(try DatabaseManager.shared.pendingServerMoves().count == 4, "four files wait to leave")
        MidgarLog.info("SERVER MOVE CRASH PASSED", category: .content)
        exit(0)
    }

    /// The second half (`--exercise-server-move-recover`), on the next launch: the scan finishes the journal before it reads
    /// the folder, so the four files are gone, nothing is listed twice and the song that stays is still there.
    private static func checkRecovery() async throws {
        try await waitFor("the journal is finished") { (try? DatabaseManager.shared.pendingServerMoves().isEmpty) == true }
        try await waitFor("the library lists the songs") { !Library.shared.allTracks.isEmpty }
        await Library.shared.reload()
        let local = Library.shared.allTracks.filter { $0.fileURL.isFileURL && LibraryPaths.relativePath(of: $0.fileURL).hasPrefix("MoveExercise/") }
        try expect(local.map { LibraryPaths.relativePath(of: $0.fileURL) } == ["MoveExercise/Only Here.m4a"], "only the song that stays is listed from the folder (\(local.count))")
        let remote = Library.shared.allTracks.filter { $0.remoteSong != nil }
        try expect(remote.count == 3, "the three server songs are listed once each (\(remote.count))")
        for name in ["01 - First Light.m4a", "02 - Second Wind.m4a", "03 - Third Rail.m4a", "Copy/01 - First Light.m4a"] {
            let path = LibraryPaths.root.appendingPathComponent("MoveExercise/" + name).path
            try expect(!FileManager.default.fileExists(atPath: path), "\(name) left the folder")
        }
    }

    private static func waitFor(_ what: String, timeout: TimeInterval = 60, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw Failure(step: what) }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func step(_ text: String) {
        MidgarLog.info("Server move exercise: \(text)", category: .content)
    }

    private static func expect(_ condition: Bool, _ what: String) throws {
        guard condition else { throw Failure(step: what) }
    }

    private static func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw Failure(step: what) }
        return value
    }
}
#endif
