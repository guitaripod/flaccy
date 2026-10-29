#if DEBUG
import FlaccyCore
import FlaccyEngine
import Foundation
import MidgarCore

/// Drives a reset against a real server and logs `RESEED EXERCISE PASSED` or `RESEED EXERCISE FAILED: <step>`. Launch with
/// `--exercise-server-reseed`, `FLACCY_EXERCISE_SERVER=<url>|<enrollment code>` and `FLACCY_EXERCISE_HANDSHAKE=<folder>`.
///
/// It builds a throwaway library of 3,000 loved songs and 40 playlists of 50, about 5,000 entities and several megabytes, connects,
/// syncs, and writes `ready` in the folder. The person running it then stops the server, restores an older backup so the server's
/// state is replaced, starts it again and writes `restored`. The exercise syncs again, which must rebuild the whole base on the
/// server in `state.reseed` mutations the server accepts, and counts what the server holds.
@MainActor
enum ServerSyncReseedExercise {

    static let launchArgument = "--exercise-server-reseed"
    static let serverKey = "FLACCY_EXERCISE_SERVER"
    static let handshakeKey = "FLACCY_EXERCISE_HANDSHAKE"
    static let songs = 3_000
    static let playlists = 40
    static let entriesPerPlaylist = 50

    private struct Failure: Error {
        let step: String
    }

    static func runIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        Task {
            do {
                try await run()
                MidgarLog.info("RESEED EXERCISE PASSED", category: .sync)
            } catch let failure as Failure {
                MidgarLog.error("RESEED EXERCISE FAILED: \(failure.step)", category: .sync)
            } catch {
                MidgarLog.error("RESEED EXERCISE FAILED: \(error.localizedDescription)", category: .sync)
            }
        }
    }

    private static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let parts = (environment[serverKey] ?? "").components(separatedBy: "|")
        guard parts.count == 2, let url = FlaccyServerLink.baseURL(from: parts[0]), let folder = environment[handshakeKey] else {
            throw Failure(step: "the environment holds \(serverKey)=url|code and \(handshakeKey)=folder")
        }
        let handshake = URL(fileURLWithPath: folder)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("flaccy-reseed-exercise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let database = try DatabaseManager(path: work.appendingPathComponent("library.sqlite").path)
        let tokens = ReseedTokens()
        let engine = ServerSyncEngine(
            database: database,
            configuration: ServerSyncConfiguration(
                transports: FlaccyServerTransports(), tokens: tokens, backoff: .none, platform: "macos", localChangeDelaySeconds: nil
            )
        )
        let run = String(UUID().uuidString.prefix(6))
        try seed(database, run: run)
        step("built \(songs) loved songs and \(playlists) playlists")
        _ = try await engine.connect(
            link: FlaccyServerLink(baseURL: url, enrollmentCode: parts[1], name: nil), deviceName: "Reseed", startSyncing: false
        )
        try await settle(engine)
        let before = try await count(url: url, tokens: tokens, run: run)
        step("the server holds \(before.playlists) playlists, \(before.entries) entries and \(before.loves) loves")
        try expect(before.playlists == playlists && before.entries == playlists * entriesPerPlaylist && before.loves == songs, "the first sync reached the server")

        try Data().write(to: handshake.appendingPathComponent("ready"))
        step("waiting for the server to be restored")
        try await waitFor(handshake.appendingPathComponent("restored"))
        let emptied = try await count(url: url, tokens: tokens, run: run)
        step("after the restore the server holds \(emptied.playlists) playlists")
        try await settle(engine)
        let after = try await count(url: url, tokens: tokens, run: run)
        step("after the reset the server holds \(after.playlists) playlists, \(after.entries) entries and \(after.loves) loves")
        try expect(after.playlists == playlists && after.entries == playlists * entriesPerPlaylist && after.loves == songs, "the reset rebuilt the base on the server")
        try expect(await engine.pendingChangeCount() == 0, "every reseed was accepted and retired")
        try expect(try database.fetchAllPlaylists().filter { $0.name.contains(run) }.count == playlists, "the playlists are still here")
    }

    private static func seed(_ database: DatabaseManager, run: String) throws {
        let padding = String(repeating: "a", count: 480)
        let tracks = (0..<songs).map { index in
            TrackRecord(
                fileURL: "reseed/\(run)/song\(index).flac", title: "Reseed Song \(index) \(run)", artist: "Reseed Artist \(index % 50) \(run)",
                albumTitle: "\(padding) \(index % 40)", trackNumber: index % 12 + 1, duration: 200, dateAdded: Date(), playCount: 0,
                aiAnalyzed: false, loved: true
            )
        }
        try database.insertTracks(tracks)
        for playlist in 0..<playlists {
            let id = try require(database.createPlaylist(name: "Reseed \(playlist) \(run)").id, "a playlist has an id")
            let files = (0..<entriesPerPlaylist).map { tracks[(playlist * entriesPerPlaylist + $0) % songs].fileURL }
            try database.addTracksToPlaylist(playlistId: id, trackFileURLs: files)
        }
    }

    private static func settle(_ engine: ServerSyncEngine) async throws {
        for _ in 0..<5 {
            if case .upToDate = await engine.syncNow() { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw Failure(step: "sync settled up to date (\(await engine.status))")
    }

    private struct Counts {
        var playlists = 0
        var entries = 0
        var loves = 0
    }

    private static func count(url: URL, tokens: ReseedTokens, run: String) async throws -> Counts {
        let client = FlaccyServerClient(baseURL: url, token: tokens.current)
        var counts = Counts()
        var ours = Set<String>()
        var since: Int64 = 0
        var changes: [ServerChange] = []
        while true {
            let page = try await client.pull(since: since, limit: 5_000, instance: "reseed-count", incarnation: nil)
            changes.append(contentsOf: page.changes)
            if !page.more { break }
            since = page.changes.last?.seq ?? page.head
        }
        for change in changes {
            if case .playlist(let playlist)? = ServerEntityValue(kind: change.kind, value: change.value), playlist.alive, playlist.name.contains(run) {
                counts.playlists += 1
                ours.insert(playlist.id)
            }
        }
        for change in changes {
            switch ServerEntityValue(kind: change.kind, value: change.value) {
            case .entry(let entry)? where entry.alive && ours.contains(entry.playlist): counts.entries += 1
            case .love(let love)? where love.loved && love.ref.title.contains(run): counts.loves += 1
            default: break
            }
        }
        return counts
    }

    private static func waitFor(_ file: URL) async throws {
        for _ in 0..<240 {
            if FileManager.default.fileExists(atPath: file.path) { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw Failure(step: "the server was restored within two minutes")
    }

    private static func step(_ text: String) {
        MidgarLog.info("RESEED EXERCISE step: \(text)", category: .sync)
    }

    private static func expect(_ condition: Bool, _ step: String) throws {
        guard condition else { throw Failure(step: step) }
    }

    private static func require<T>(_ value: T?, _ step: String) throws -> T {
        guard let value else { throw Failure(step: step) }
        return value
    }
}

private final class ReseedTokens: ServerTokenStore, @unchecked Sendable {

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
