#if DEBUG
import FlaccyCore
import FlaccyEngine
import Foundation
import MidgarCore

/// Drives the whole Flaccy Server sync against a real server and logs `SERVER EXERCISE PASSED` or
/// `SERVER EXERCISE FAILED: <step>`. Launch with `--exercise-server` and the environment variable
/// `FLACCY_EXERCISE_SERVER=<url>|<enrollment code>` (or the same text as the argument after the flag).
///
/// Everything it creates carries a run tag in its name, so a server that already holds other data is fine.
///
/// It never touches the app's own library or Keychain: it builds a throwaway database in the temporary directory and keeps
/// the device token in memory. It seeds songs, a playlist, a love and two plays, connects (the first-connect import), checks the
/// server's own state through a second client, edits more on this side, pushes a rename, a love and a play from another instance
/// of the same device, syncs again and checks they arrived in the database, then disconnects and checks nothing local was lost.
@MainActor
enum ServerSyncExercise {

    static let launchArgument = "--exercise-server"
    static let environmentKey = "FLACCY_EXERCISE_SERVER"

    private struct Failure: Error {
        let step: String
    }

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task {
            do {
                try await run()
                MidgarLog.info("SERVER EXERCISE PASSED", category: .sync)
            } catch let failure as Failure {
                MidgarLog.error("SERVER EXERCISE FAILED: \(failure.step)", category: .sync)
            } catch {
                MidgarLog.error("SERVER EXERCISE FAILED: \(error.localizedDescription)", category: .sync)
            }
        }
    }

    private static func run() async throws {
        let (url, code) = try arguments()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("flaccy-server-exercise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try DatabaseManager(path: folder.appendingPathComponent("library.sqlite").path)
        let tokens = ExerciseTokens()
        let engine = ServerSyncEngine(
            database: database,
            configuration: ServerSyncConfiguration(
                transports: FlaccyServerTransports(), tokens: tokens, backoff: .none, platform: platform,
                localChangeDelaySeconds: 0.2
            )
        )

        let run = String(UUID().uuidString.prefix(6))
        let songs = try seed(database, run: run)
        step("seeded \(songs.count) songs, a playlist, a love and two plays")

        let connection = try await engine.connect(
            link: FlaccyServerLink(baseURL: url, enrollmentCode: code, name: nil), deviceName: "Exercise"
        )
        step("connected to \(connection.serverName); queued \(connection.imported)")
        try expect(connection.imported.playlists == 1 && connection.imported.entries == 2, "the import queued the playlist and its two songs")
        try expect(connection.imported.loves == 1, "the import queued the love")

        try await settle(engine)
        let first = try await serverView(url: url, tokens: tokens, run: run)
        try expect(first.playlists.count == 1, "the server holds the playlist (\(first.playlists.count))")
        try expect(first.aliveEntries == 2, "the server holds both entries (\(first.aliveEntries))")
        try expect(first.loved == 1, "the server holds the love (\(first.loved))")
        try expect(first.listens == 2, "the server holds both plays (\(first.listens))")
        try expect(await engine.pendingChangeCount() == 0, "a complete pull retired every mutation")

        try edit(database, songs: songs, run: run)
        try await settle(engine)
        let second = try await serverView(url: url, tokens: tokens, run: run)
        try expect(second.playlists.count == 2, "the server holds the new playlist (\(second.playlists.count))")
        try expect(second.names.contains("Exercise renamed \(run)"), "the server holds the rename (\(second.names))")
        try expect(second.aliveEntries == 4, "the server holds the new entries (\(second.aliveEntries))")
        try expect(second.loved == 2, "the server holds the second love (\(second.loved))")
        try expect(second.listens == 3, "the server holds the third play (\(second.listens))")
        let cover = try require(second.playlists.first { $0.name == "Second \(run)" }?.coverBlob, "the server holds the cover of the second playlist")
        let stored = try await FlaccyServerClient(baseURL: url, token: tokens.current).blob(hash: cover)
        try expect(stored == coverImage, "the server returns the cover bytes it was given")

        try await editFromAnotherInstance(url: url, tokens: tokens, view: second, songs: songs, run: run)
        try await settle(engine)
        let names = try database.fetchAllPlaylists().map(\.name).filter { $0.contains(run) }
        try expect(names.contains("Second renamed elsewhere \(run)"), "the remote rename reached the database (\(names))")
        let lovedPaths = try database.fetchLovedFileURLs()
        try expect(lovedPaths.contains(songs[2].fileURL), "the remote love reached the database")
        let history = try database.fetchAllScrobbleRows().filter { $0.trackTitle.contains(run) }
        try expect(history.count == 4, "the remote play reached the history (\(history.count) plays of this run)")
        step("a rename, a love and a play made elsewhere arrived")

        try await engine.disconnect()
        try expect(!database.serverSyncGate.isConfigured, "disconnecting turns the recorder off")
        try expect(tokens.token(serverID: "any") == nil, "disconnecting forgets the token")
        try expect(try database.fetchAllPlaylists().filter { $0.name.contains(run) }.count == 2, "disconnecting leaves the playlists in place")
        step("disconnected; the library is untouched")
    }

    private static let coverImage = Data(base64Encoded: "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=") ?? Data()

    private static var platform: String {
        #if os(macOS)
        "macos"
        #else
        "ios"
        #endif
    }

    private static func arguments() throws -> (URL, String) {
        let arguments = CommandLine.arguments
        let flagged = arguments.firstIndex(of: launchArgument).flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        let text = ProcessInfo.processInfo.environment[environmentKey] ?? flagged ?? ""
        let parts = text.components(separatedBy: "|")
        guard parts.count == 2, let url = FlaccyServerLink.baseURL(from: parts[0]), !parts[1].isEmpty else {
            throw Failure(step: "the environment variable \(environmentKey) holds url|enrollment code")
        }
        return (url, parts[1])
    }

    private static func seed(_ database: DatabaseManager, run: String) throws -> [TrackRecord] {
        let tracks = (1...4).map { index in
            TrackRecord(
                fileURL: "exercise/song\(index).flac", title: "Exercise Song \(index) \(run)", artist: "Exercise Artist \(run)",
                albumTitle: "Exercise Album", trackNumber: index, duration: 180, dateAdded: Date(), playCount: 0,
                aiAnalyzed: false
            )
        }
        for track in tracks { try database.insertTrack(track) }
        let playlist = try database.createPlaylist(name: "Exercise \(run)")
        let playlistID = try require(playlist.id, "the playlist has an id")
        try database.addTracksToPlaylist(playlistId: playlistID, trackFileURLs: tracks.prefix(2).map(\.fileURL))
        try database.setLoved(fileURL: tracks[0].fileURL, loved: true, pendingOp: nil)
        let start = Date().addingTimeInterval(-3_600)
        for (offset, track) in tracks.prefix(2).enumerated() {
            try database.insertScrobble(ScrobbleRecord(
                trackTitle: track.title, artist: track.artist, albumTitle: track.albumTitle,
                timestamp: start.addingTimeInterval(Double(offset) * 300), duration: 180, submitted: true
            ))
        }
        return tracks
    }

    private static func edit(_ database: DatabaseManager, songs: [TrackRecord], run: String) throws {
        let playlists = try database.fetchAllPlaylists()
        let first = try require(playlists.first { $0.name == "Exercise \(run)" }?.id, "the first playlist exists")
        try database.renamePlaylist(id: first, name: "Exercise renamed \(run)")
        let second = try database.createPlaylist(name: "Second \(run)")
        let secondID = try require(second.id, "the second playlist has an id")
        try database.addTracksToPlaylist(playlistId: secondID, trackFileURLs: [songs[2].fileURL, songs[3].fileURL])
        let rows = try database.fetchPlaylistTracks(playlistId: secondID)
        for (index, row) in rows.reversed().enumerated() {
            try database.reorderPlaylistTrack(id: try require(row.id, "a playlist row has an id"), newPosition: index)
        }
        try database.savePlaylistCover(coverImage, id: secondID)
        try database.setLoved(fileURL: songs[1].fileURL, loved: true, pendingOp: nil)
        try database.insertScrobble(ScrobbleRecord(
            trackTitle: songs[2].title, artist: songs[2].artist, albumTitle: songs[2].albumTitle,
            timestamp: Date().addingTimeInterval(-60), duration: 180, submitted: true
        ))
        step("edited: a rename, a second playlist with two songs reordered and a cover, a love and a play")
    }

    private static func settle(_ engine: ServerSyncEngine) async throws {
        for _ in 0..<4 {
            let status = await engine.syncNow()
            if case .upToDate = status { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw Failure(step: "sync settled up to date (\(await engine.status))")
    }

    private struct ServerView {
        var playlists: [ServerPlaylistValue] = []
        var aliveEntries = 0
        var loved = 0
        var listens = 0
        var names: [String] { playlists.map(\.name) }
    }

    private static func serverView(url: URL, tokens: ExerciseTokens, run: String) async throws -> ServerView {
        let client = FlaccyServerClient(baseURL: url, token: tokens.current)
        let pull = try await client.pull(since: 0, limit: 5_000, instance: "exercise-view", incarnation: nil)
        var view = ServerView()
        var ours = Set<String>()
        for change in pull.changes {
            if case .playlist(let playlist)? = ServerEntityValue(kind: change.kind, value: change.value),
               playlist.alive, playlist.name.contains(run) {
                view.playlists.append(playlist)
                ours.insert(playlist.id)
            }
        }
        for change in pull.changes {
            switch ServerEntityValue(kind: change.kind, value: change.value) {
            case .entry(let entry)? where entry.alive && ours.contains(entry.playlist): view.aliveEntries += 1
            case .love(let love)? where love.loved && love.ref.title.contains(run): view.loved += 1
            default: break
            }
        }
        let listens = try await client.listens(before: 4_102_444_800, after: nil, limit: 5_000, incarnation: nil)
        view.listens = listens.listens.filter { !$0.suppressed && $0.ref.title.contains(run) }.count
        return view
    }

    private static func editFromAnotherInstance(
        url: URL, tokens: ExerciseTokens, view: ServerView, songs: [TrackRecord], run: String
    ) async throws {
        let client = FlaccyServerClient(baseURL: url, token: tokens.current)
        let devices = try await client.devices()
        let device = try require(devices.first { $0.current }, "the server lists this device")
        let playlist = try require(view.playlists.first { $0.name == "Second \(run)" }, "the second playlist is on the server")
        let song = songs[2]
        let key = try ServerSongIdentity.songKey(title: song.title, artist: song.artist)
        let ref = ServerSongRef(songKey: key, title: song.title, artist: song.artist, album: song.albumTitle)
        let refJSON = try JSONDecoder().decode(ServerJSON.self, from: JSONEncoder().encode(ref))
        let now = Int64(Date().timeIntervalSince1970 * 1000) << 16
        let listenID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
        let listen: ServerJSON = [
            "listens": [["eventId": .string(listenID), "ts": .int(Int64(Date().timeIntervalSince1970) - 30), "ref": refJSON, "playedS": 90, "recorded": true]],
        ]
        let mutations = [
            ServerMutation(id: 1, name: "playlist.rename", stamp: now, args: ["id": .string(playlist.id), "name": .string("Second renamed elsewhere \(run)")]),
            ServerMutation(id: 2, name: "love.set", stamp: now + 1, args: ["songKey": .string(key), "ref": refJSON, "loved": true]),
            ServerMutation(id: 3, name: "listen.record", stamp: now + 2, args: listen),
        ]
        let response = try await client.push(
            ServerPushRequest(device: device.id, instance: "exercise-elsewhere", mutations: mutations), incarnation: nil
        )
        try expect(response.results.allSatisfy { $0.status == .applied }, "the server applied the edits made elsewhere (\(response.results))")
    }

    private static func step(_ text: String) {
        MidgarLog.info("SERVER EXERCISE step: \(text)", category: .sync)
    }

    private static func expect(_ condition: Bool, _ step: String) throws {
        guard condition else { throw Failure(step: step) }
    }

    private static func require<T>(_ value: T?, _ step: String) throws -> T {
        guard let value else { throw Failure(step: step) }
        return value
    }
}

private final class ExerciseTokens: ServerTokenStore, @unchecked Sendable {

    private let lock = NSLock()
    private var stored: String?

    var current: String? { lock.withLock { stored } }

    func token(serverID: String) -> String? { current }

    func setToken(_ token: String, serverID: String) throws {
        lock.withLock { stored = token }
    }

    func removeToken(serverID: String) {
        lock.withLock { stored = nil }
    }
}
#endif
