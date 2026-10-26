import Foundation
import MidgarCore
import FlaccyCore
import GRDB

extension DatabaseManager {

    public func setLoved(fileURL: String, loved: Bool, pendingOp: String?) throws {
        try dbQueue.write { db in
            let recorder = try ServerSyncRecorder(db, gate: serverSyncGate)
            let wasLoved = try recorder == nil ? loved : Self.storedLoved(db, fileURL: fileURL)
            try db.execute(
                sql: "UPDATE tracks SET loved = ?, lovedPendingOp = ? WHERE fileURL = ?",
                arguments: [loved, pendingOp, fileURL]
            )
            if wasLoved != loved {
                try recorder?.loved(fileURL: fileURL, loved: loved)
            }
        }
    }

    public func fetchLovedFileURLs() throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT fileURL FROM tracks WHERE loved = 1"))
        }
    }

    public func fetchPendingLoveOps() throws -> [(fileURL: String, title: String, artist: String, op: String)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT fileURL, title, artist, lovedPendingOp FROM tracks
                WHERE lovedPendingOp IS NOT NULL
            """)
            return rows.map { (fileURL: $0["fileURL"], title: $0["title"], artist: $0["artist"], op: $0["lovedPendingOp"]) }
        }
    }

    public func clearPendingLoveOp(fileURL: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tracks SET lovedPendingOp = NULL WHERE fileURL = ?", arguments: [fileURL])
        }
    }

    /// Applies a loved state matched by title+artist (used when syncing from
    /// Last.fm, which keys on names rather than file URLs).
    public func markLoved(paths: [String], loved: Bool) throws {
        guard !paths.isEmpty else { return }
        try dbQueue.write { db in
            let recorder = try ServerSyncRecorder(db, gate: serverSyncGate)
            let changing = recorder == nil ? [] : try TrackRecord
                .filter(paths.contains(Column("fileURL")) && Column("loved") != loved)
                .select(Column("fileURL"), as: String.self)
                .fetchAll(db)
            _ = try TrackRecord
                .filter(paths.contains(Column("fileURL")))
                .updateAll(db, Column("loved").set(to: loved))
            for fileURL in changing {
                try recorder?.loved(fileURL: fileURL, loved: loved)
            }
        }
    }

    private static func storedLoved(_ db: Database, fileURL: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT loved FROM tracks WHERE fileURL = ?", arguments: [fileURL]) ?? false
    }
}
