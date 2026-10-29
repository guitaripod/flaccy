import FlaccyCore
import FlaccyServerCore
import Foundation
import GRDB
import XCTest

@testable import FlaccyEngine

/// One device: its own library database, token store and sync engine, wired to a fake server.
final class SyncDevice: @unchecked Sendable {

    let folder: URL
    let database: DatabaseManager
    let engine: ServerSyncEngine
    let tokens = MemoryTokens()
    let sink = RecordingSink()
    private let state = State()

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var isEntitled = true
        private var seconds: [Double] = []

        var entitled: Bool {
            get { lock.withLock { isEntitled } }
            set { lock.withLock { isEntitled = newValue } }
        }

        var pauses: [Double] { lock.withLock { seconds } }
        func record(_ pause: Double) { lock.withLock { seconds.append(pause) } }
    }

    static let link = FlaccyServerLink(baseURL: URL(string: "http://fake:4545") ?? URL(fileURLWithPath: "/"), enrollmentCode: "GOODCODE", name: "Fake")

    init(
        server: FakeFlaccyServer, transports: (any ServerSyncTransportFactory)? = nil, backoff: ServerSyncBackoff = .none,
        copying source: SyncDevice? = nil
    ) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        let path = folder.appendingPathComponent("library.sqlite").path
        if let source {
            try source.database.dbQueue.writeWithoutTransaction { try $0.execute(sql: "VACUUM INTO ?", arguments: [path]) }
        }
        let database = try DatabaseManager(path: path)
        self.database = database
        let state = self.state
        engine = ServerSyncEngine(
            database: database,
            configuration: ServerSyncConfiguration(
                transports: transports ?? FakeTransports(server: server), tokens: tokens, scalarSink: sink, backoff: backoff,
                platform: "ios", isEntitled: { state.entitled }, sleep: { state.record($0) }, jitter: { 0.5 },
                localChangeDelaySeconds: nil, periodSeconds: 1
            )
        )
    }

    /// Hands this device the token of the device it was copied from, as a restored backup would carry it.
    func adoptToken(of source: SyncDevice, serverID: String) throws {
        if let token = source.tokens.token(serverID: serverID) { try tokens.setToken(token, serverID: serverID) }
    }

    var entitled: Bool {
        get { state.entitled }
        set { state.entitled = newValue }
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    var recordedPauses: [Double] { state.pauses }

    func connect(code: String = "GOODCODE", startSyncing: Bool = false) async throws -> ServerSyncConnection {
        let link = FlaccyServerLink(baseURL: SyncDevice.link.baseURL, enrollmentCode: code, name: "Fake")
        return try await engine.connect(link: link, deviceName: "Test", startSyncing: startSyncing)
    }

    @discardableResult
    func settle(file: StaticString = #filePath, line: UInt = #line) async -> SyncStatus {
        let status = await engine.syncNow()
        return status
    }

    @discardableResult
    func addTrack(
        _ title: String, artist: String = "Artist", album: String = "Album", path: String? = nil, duration: Double = 200,
        codec: String? = "FLAC"
    ) throws -> TrackRecord {
        try database.insertTrack(TrackRecord(
            fileURL: path ?? "\(artist)/\(album)/\(title).flac", title: title, artist: artist, albumTitle: album, trackNumber: 1,
            duration: duration, dateAdded: Date(), playCount: 0, aiAnalyzed: false, codec: codec
        ))
    }

    func songKey(_ title: String, artist: String = "Artist") throws -> String {
        try ServerSongIdentity.songKey(title: title, artist: artist)
    }

    func read<T>(_ body: (Database) throws -> T) throws -> T {
        try database.dbQueue.read(body)
    }

    func write<T>(_ body: (Database) throws -> T) throws -> T {
        try database.dbQueue.write(body)
    }

    func playlistNames() throws -> [String] {
        try read { try String.fetchAll($0, sql: "SELECT name FROM playlists ORDER BY name") }
    }

    func playlistID(_ name: String) throws -> Int64 {
        try XCTUnwrap(read { try Int64.fetchOne($0, sql: "SELECT id FROM playlists WHERE name = ?", arguments: [name]) })
    }

    func playlistTitles(_ name: String) throws -> [String] {
        try read { db in
            try String.fetchAll(db, sql: """
                SELECT t.title FROM playlistTracks pt JOIN playlists p ON p.id = pt.playlistId
                JOIN tracks t ON t.fileURL = pt.trackFileURL WHERE p.name = ? ORDER BY pt.position, pt.id
                """, arguments: [name])
        }
    }

    func pendingNames() throws -> [String] {
        try read { try String.fetchAll($0, sql: "SELECT name FROM sync_pending ORDER BY mutation_id") }
    }

    func pendingRows() throws -> [(id: Int64, name: String, acked: Bool, failed: Bool)] {
        try read { db in
            try Row.fetchAll(db, sql: "SELECT mutation_id, name, acked, failed FROM sync_pending ORDER BY mutation_id").map {
                ($0["mutation_id"], $0["name"], ($0["acked"] as Int) != 0, ($0["failed"] as Int) != 0)
            }
        }
    }

    func isLoved(_ path: String) throws -> Bool {
        try read { try Bool.fetchOne($0, sql: "SELECT loved FROM tracks WHERE fileURL = ?", arguments: [path]) ?? false }
    }

    func scrobbleCount() throws -> Int {
        try read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM scrobbles") ?? 0 }
    }

    func meta(_ key: String) throws -> String? {
        try read { try SyncMeta.get($0, key) }
    }

    func play(_ title: String, artist: String = "Artist", at seconds: TimeInterval, duration: Int = 200) throws {
        try database.insertScrobble(ScrobbleRecord(
            trackTitle: title, artist: artist, albumTitle: "Album", timestamp: Date(timeIntervalSince1970: seconds),
            duration: duration, submitted: true
        ))
    }
}

extension XCTestCase {
    func makeDevice(_ server: FakeFlaccyServer, backoff: ServerSyncBackoff = .none) throws -> SyncDevice {
        try SyncDevice(server: server, backoff: backoff)
    }

    func assertUpToDate(_ status: SyncStatus, file: StaticString = #filePath, line: UInt = #line) {
        guard case .upToDate = status else { return XCTFail("expected up to date, got \(status)", file: file, line: line) }
    }
}
