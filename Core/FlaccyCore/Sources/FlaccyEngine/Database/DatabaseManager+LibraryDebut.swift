import Foundation
import MidgarCore
import FlaccyCore
import GRDB

extension DatabaseManager {

    public func libraryDebut() throws -> LibraryDebutSummary? {
        try dbQueue.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT summaryJSON FROM libraryDebut WHERE id = 1") else {
                return nil
            }
            do {
                return try Self.debutDecoder().decode(LibraryDebutSummary.self, from: Data(json.utf8))
            } catch {
                MidgarLog.error("Library debut summary unreadable: \(error.localizedDescription)", category: .database)
                return nil
            }
        }
    }

    public func saveLibraryDebut(_ summary: LibraryDebutSummary) throws {
        let json = String(decoding: try Self.debutEncoder().encode(summary), as: UTF8.self)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO libraryDebut (id, completedAt, summaryJSON) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    completedAt = excluded.completedAt,
                    summaryJSON = excluded.summaryJSON
                """, arguments: [summary.completedAt, json])
        }
    }

    public func clearLibraryDebut() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM libraryDebut")
        }
    }

    #if DEBUG
    /// Empties every table the screenshot demo fills, in one transaction, so a
    /// relaunch can reseed from nothing without a half-wiped store ever being
    /// visible. Reachable only from the DEBUG simulator demo.
    public func eraseDemoContent() throws {
        let tables = [
            "playlistTracks", "playlists", "lyrics", "scrobbles", "wantlist", "newReleaseCache",
            "enrichmentState", "weeklyChartCache", "similarArtistCache", "albumInfo", "artists", "tracks",
        ]
        try dbQueue.write { db in
            for table in tables {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
        scrobbleRevisionCounter.bump()
    }
    #endif

    private static func debutEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func debutDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
