import Foundation
import MidgarCore
import FlaccyCore
import GRDB

extension DatabaseManager {

    public func fetchCachedSimilarArtists(artist: String, fresherThan: Date) throws -> [(similarName: String, match: Double)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT similarName, match FROM similarArtistCache
                WHERE artist = ? AND fetchedAt >= ?
                ORDER BY match DESC
            """, arguments: [artist, fresherThan])
            return rows.map { (similarName: $0["similarName"], match: $0["match"]) }
        }
    }

    public func saveSimilarArtists(artist: String, entries: [(name: String, match: Double)]) throws {
        try dbQueue.write { db in
            let now = Date()
            for entry in entries {
                try db.execute(sql: """
                    INSERT INTO similarArtistCache (artist, similarName, match, fetchedAt) VALUES (?, ?, ?, ?)
                    ON CONFLICT(artist, similarName) DO UPDATE SET match = excluded.match, fetchedAt = excluded.fetchedAt
                """, arguments: [artist, entry.name, entry.match, now])
            }
        }
    }

    func fetchWeeklyChart(chartType: String, fromUts: Int, toUts: Int) throws -> [WeeklyChartCacheRecord] {
        try dbQueue.read { db in
            try WeeklyChartCacheRecord
                .filter(Column("chartType") == chartType && Column("fromUts") == fromUts && Column("toUts") == toUts)
                .order(Column("rank").asc)
                .fetchAll(db)
        }
    }

    func saveWeeklyChart(_ records: [WeeklyChartCacheRecord]) throws {
        guard !records.isEmpty else { return }
        try dbQueue.write { db in
            for record in records {
                try record.insert(db)
            }
        }
    }
}
