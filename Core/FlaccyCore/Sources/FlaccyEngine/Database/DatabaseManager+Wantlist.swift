import Foundation
import MidgarCore
import FlaccyCore
import GRDB

extension DatabaseManager {

    public func fetchWantlist(states: [String]) throws -> [WantlistRecord] {
        try dbQueue.read { db in
            try WantlistRecord
                .filter(states.contains(Column("state")))
                .order(Column("score").desc, Column("addedAt").desc)
                .fetchAll(db)
        }
    }

    /// Inserts unseen suggestions and refreshes still-wanted ones; rows the
    /// user has dismissed or acquired are left untouched so a suggestion can
    /// never resurrect itself.
    public func mergeWantlistSuggestions(_ records: [WantlistRecord]) throws {
        try dbQueue.write { db in
            for record in records {
                if var existing = try WantlistRecord.filter(Column("normKey") == record.normKey).fetchOne(db) {
                    guard existing.state == WantlistState.wanted.rawValue else { continue }
                    existing.score = record.score
                    existing.reason = record.reason
                    existing.playCount = record.playCount
                    if existing.imageURL == nil { existing.imageURL = record.imageURL }
                    try existing.update(db)
                } else {
                    try record.insert(db)
                }
            }
        }
    }

    public func updateWantlistState(normKey: String, state: String, resolvedAt: Date?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE wantlist SET state = ?, resolvedAt = ? WHERE normKey = ?",
                arguments: [state, resolvedAt, normKey]
            )
        }
    }

    public func acknowledgeWantlist() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE wantlist SET acknowledged = 1 WHERE acknowledged = 0")
        }
    }

    public func unacknowledgedWantedCount() throws -> Int {
        try dbQueue.read { db in
            try WantlistRecord
                .filter(Column("state") == WantlistState.wanted.rawValue && Column("acknowledged") == false)
                .fetchCount(db)
        }
    }

    public func replaceNewReleases(_ records: [NewReleaseRecord]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM newReleaseCache")
            for record in records {
                try record.insert(db)
            }
        }
    }

    public func fetchNewReleases() throws -> [NewReleaseRecord] {
        try dbQueue.read { db in
            try NewReleaseRecord.order(Column("releaseDate").desc).fetchAll(db)
        }
    }

    public func newReleasesFetchedAt() throws -> Date? {
        try dbQueue.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(fetchedAt) FROM newReleaseCache")
        }
    }
}
