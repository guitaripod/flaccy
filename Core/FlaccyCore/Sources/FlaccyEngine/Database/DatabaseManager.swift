import Foundation
import MidgarCore
import FlaccyCore
import GRDB

public final class DatabaseManager: Sendable {

    public static let shared = DatabaseManager()

    let dbQueue: DatabaseQueue
    let scrobbleRevisionCounter = RevisionCounter()

    /// Whether a Flaccy Server is configured, read by every write path that records for sync.
    public let serverSyncGate: ServerSyncGate

    /// Rows stamped before this instant are "undated": an old scrobbler bug left
    /// imported histories with plays at 1970-01-01. They still count toward
    /// totals and top lists, but placing them on a calendar, a clock or a
    /// streak would stretch every one of those across fifty years of nothing.
    public static let firstDatedScrobble = Date(timeIntervalSince1970: 1_009_843_200)

    private init() {
        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dbDirectory = appSupport.appendingPathComponent("flaccy", isDirectory: true)
            try FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
            let dbPath = dbDirectory.appendingPathComponent("library.sqlite").path
            do {
                dbQueue = try Self.openDatabase(at: dbPath)
            } catch {
                MidgarLog.error("Database open/migrate failed, recreating: \(error.localizedDescription)", category: .database)
                Self.moveCorruptDatabaseAside(at: dbPath)
                dbQueue = try Self.openDatabase(at: dbPath)
            }
            let state = Self.serverSyncState(dbQueue)
            serverSyncGate = ServerSyncGate(configured: state.configured, recording: state.recording)
            MidgarLog.info("Database initialized at \(dbPath)", category: .database)
        } catch {
            fatalError("Failed to initialize database after recovery attempt: \(error)")
        }
    }

    /// Opens a database at an arbitrary path, for tests that need to watch the
    /// real migrator run against a fixture instead of the app's own library.
    /// Nothing in the app uses it: the app has exactly one database, `shared`.
    public init(path: String, clock: @escaping @Sendable () -> Int64 = ServerSyncGate.systemClock) throws {
        let queue = try Self.openDatabase(at: path)
        dbQueue = queue
        let state = Self.serverSyncState(queue)
        serverSyncGate = ServerSyncGate(configured: state.configured, recording: state.recording, clock: clock)
    }

    private static func serverSyncState(_ queue: DatabaseQueue) -> (configured: Bool, recording: Bool) {
        let state = try? queue.read { (try SyncMeta.isConfigured($0), try SyncMeta.get($0, SyncMeta.recording) != nil) }
        return state ?? (false, false)
    }

    /// Writes a consistent copy of the whole library to `url`, taken while the app keeps using it.
    public func writeSnapshot(to url: URL) throws {
        let destination = try DatabaseQueue(path: url.path)
        try dbQueue.backup(to: destination)
    }

    /// Opens the SQLite database and runs all migrations, throwing instead of crashing
    /// so a corrupt file can be moved aside and the library rebuilt from Documents.
    static func openDatabase(at path: String) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.prepareDatabase { db in db.add(function: enrichmentKeyNormalizer) }
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        try migrator().migrate(queue)
        return queue
    }

    /// The key normalizer every enrichment statement calls, installed on each
    /// connection before the migrator runs so the v10 seeds get it too.
    ///
    /// SQLite's own `lower()` folds ASCII only and its `trim()` strips spaces
    /// only, so an album titled "Ágætis byrjun" would be keyed one way by the
    /// queue and another by `EnrichmentKey`, which reads and writes the row —
    /// and the orphan sweep would delete the state on every sync that removes a
    /// file. `pure` maps to SQLITE_DETERMINISTIC, so the index seek on
    /// `enrichmentState(scope, key)` survives.
    private static let enrichmentKeyNormalizer = DatabaseFunction(
        EnrichmentKey.sqlFunctionName, argumentCount: 1, pure: true
    ) { arguments in
        guard let value = String.fromDatabaseValue(arguments[0]) else { return nil }
        return EnrichmentKey.normalize(value)
    }

    private static func moveCorruptDatabaseAside(at path: String) {
        let fm = FileManager.default
        let timestamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let source = path + suffix
            guard fm.fileExists(atPath: source) else { continue }
            let destination = path + ".corrupt-\(timestamp)" + suffix
            do {
                try fm.moveItem(atPath: source, toPath: destination)
            } catch {
                try? fm.removeItem(atPath: source)
            }
        }
    }

}

/// A counter several threads can bump and read, used to version caches built
/// from a table the database owns.
final class RevisionCounter: @unchecked Sendable {

    private let lock = NSLock()
    private var count = 0

    public var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    public func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
