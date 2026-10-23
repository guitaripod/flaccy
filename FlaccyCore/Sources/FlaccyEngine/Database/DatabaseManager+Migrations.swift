import Foundation
import MidgarCore
import FlaccyCore
import GRDB

extension DatabaseManager {

    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "tracks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fileURL", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("albumTitle", .text).notNull()
                t.column("trackNumber", .integer).notNull()
                t.column("duration", .double).notNull()
                t.column("artworkData", .blob)
                t.column("lastFMArtworkURL", .text)
                t.column("musicBrainzID", .text)
                t.column("albumMusicBrainzID", .text)
                t.column("dateAdded", .datetime).notNull()
                t.column("lastPlayed", .datetime)
                t.column("playCount", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "tracks_on_artist", on: "tracks", columns: ["artist"])
            try db.create(index: "tracks_on_albumTitle_artist", on: "tracks", columns: ["albumTitle", "artist"])

            try db.create(table: "artists") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("bio", .text)
                t.column("imageURL", .text)
                t.column("musicBrainzID", .text)
                t.column("lastFetched", .datetime)
            }

            try db.create(table: "albumInfo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("coverArtURL", .text)
                t.column("coverArtData", .blob)
                t.column("musicBrainzID", .text)
                t.column("year", .text)
                t.column("genre", .text)
                t.column("lastFetched", .datetime)
                t.uniqueKey(["title", "artist"])
            }
            try db.create(index: "albumInfo_on_artist", on: "albumInfo", columns: ["artist"])

            try db.create(table: "scrobbles") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackTitle", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("albumTitle", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("duration", .integer).notNull()
                t.column("submitted", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "scrobbles_on_submitted", on: "scrobbles", columns: ["submitted"])
        }

        migrator.registerMigration("v2") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "aiAnalyzed", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v3") { db in
            try db.create(table: "playlists") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "playlistTracks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("playlistId", .integer).notNull().references("playlists", onDelete: .cascade)
                t.column("trackFileURL", .text).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(index: "playlistTracks_on_playlistId", on: "playlistTracks", columns: ["playlistId"])
        }

        migrator.registerMigration("v4") { db in
            try db.create(table: "lyrics") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackTitle", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("syncedLyrics", .text)
                t.column("plainLyrics", .text)
                t.column("instrumental", .boolean).notNull().defaults(to: false)
                t.uniqueKey(["trackTitle", "artist"])
            }
        }

        migrator.registerMigration("v5") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "analysisAttemptedAt", .datetime)
            }

            try db.execute(sql: """
                INSERT INTO albumInfo (title, artist, coverArtData)
                SELECT albumTitle, artist, artworkData FROM tracks
                WHERE artworkData IS NOT NULL AND albumTitle <> ''
                GROUP BY albumTitle, artist
                ON CONFLICT(title, artist) DO UPDATE SET coverArtData = excluded.coverArtData
                WHERE albumInfo.coverArtData IS NULL
            """)
            try db.execute(sql: "UPDATE tracks SET artworkData = NULL WHERE artworkData IS NOT NULL AND albumTitle <> ''")

            try db.execute(sql: "DELETE FROM playlistTracks WHERE trackFileURL NOT IN (SELECT fileURL FROM tracks)")
        }

        migrator.registerMigration("v6") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "codec", .text)
                t.add(column: "bitDepth", .integer)
                t.add(column: "sampleRate", .integer)
                t.add(column: "channels", .integer)
                t.add(column: "loved", .boolean).notNull().defaults(to: false)
                t.add(column: "lovedPendingOp", .text)
            }
            try db.create(index: "tracks_on_loved", on: "tracks", columns: ["loved"])

            try db.create(table: "weeklyChartCache") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chartType", .text).notNull()
                t.column("fromUts", .integer).notNull()
                t.column("toUts", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("artist", .text)
                t.column("playCount", .integer).notNull().defaults(to: 0)
                t.column("rank", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "weeklyChartCache_on_type_range", on: "weeklyChartCache", columns: ["chartType", "fromUts", "toUts"])

            try db.create(table: "similarArtistCache") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("artist", .text).notNull()
                t.column("similarName", .text).notNull()
                t.column("match", .double).notNull().defaults(to: 0)
                t.column("fetchedAt", .datetime).notNull()
                t.uniqueKey(["artist", "similarName"])
            }
        }

        migrator.registerMigration("v7") { db in
            try db.create(table: "wantlist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("normKey", .text).notNull().unique()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("imageURL", .text)
                t.column("state", .text).notNull()
                t.column("source", .text).notNull()
                t.column("score", .double).notNull().defaults(to: 0)
                t.column("reason", .text).notNull().defaults(to: "")
                t.column("playCount", .integer).notNull().defaults(to: 0)
                t.column("addedAt", .datetime).notNull()
                t.column("resolvedAt", .datetime)
                t.column("acknowledged", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "wantlist_on_state", on: "wantlist", columns: ["state"])

            try db.create(table: "newReleaseCache") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("artist", .text).notNull()
                t.column("albumTitle", .text).notNull()
                t.column("releaseDate", .datetime).notNull()
                t.column("imageURL", .text)
                t.column("storeURL", .text)
                t.column("fetchedAt", .datetime).notNull()
                t.uniqueKey(["artist", "albumTitle"])
            }
        }

        migrator.registerMigration("v8") { db in
            try db.drop(index: "scrobbles_on_submitted")
            try db.create(index: "scrobbles_on_submitted_timestamp", on: "scrobbles", columns: ["submitted", "timestamp"])
            try db.create(index: "scrobbles_on_timestamp", on: "scrobbles", columns: ["timestamp"])
        }

        migrator.registerMigration("v9") { db in
            try db.alter(table: "lyrics") { t in
                t.add(column: "fetchedAt", .datetime)
            }
        }

        migrator.registerMigration("v10") { db in
            try db.create(table: "enrichmentState", options: [.withoutRowID]) { t in
                t.column("scope", .text).notNull()
                t.column("key", .text).notNull()
                t.column("version", .integer).notNull().defaults(to: 0)
                t.column("status", .integer).notNull().defaults(to: 0)
                t.column("fields", .integer).notNull().defaults(to: 0)
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("lastAttemptAt", .datetime)
                t.column("nextEligibleAt", .datetime)
                t.column("lastFailure", .text)
                t.primaryKey(["scope", "key"])
            }
            try db.create(
                index: "enrichmentState_on_due", on: "enrichmentState",
                columns: ["scope", "status", "nextEligibleAt"]
            )

            try db.create(table: "libraryDebut") { t in
                t.column("id", .integer).primaryKey().check { $0 == 1 }
                t.column("completedAt", .datetime).notNull()
                t.column("summaryJSON", .text).notNull()
            }

            try db.execute(sql: """
                INSERT INTO albumInfo (title, artist, coverArtData)
                SELECT albumTitle, artist, artworkData FROM tracks
                WHERE artworkData IS NOT NULL AND albumTitle <> ''
                GROUP BY albumTitle, artist
                ON CONFLICT(title, artist) DO UPDATE SET coverArtData = excluded.coverArtData
                WHERE albumInfo.coverArtData IS NULL
                """)
            try db.execute(sql: """
                UPDATE tracks SET artworkData = NULL
                WHERE artworkData IS NOT NULL AND albumTitle <> ''
                """)

            try db.execute(sql: """
                INSERT OR IGNORE INTO enrichmentState
                    (scope, key, version, status, fields, attempts, lastAttemptAt, nextEligibleAt, lastFailure)
                SELECT 'album',
                       flaccy_norm(title) || char(31) || flaccy_norm(artist),
                       0,
                       CASE WHEN coverArtData IS NOT NULL AND year IS NOT NULL THEN 1 ELSE 0 END,
                         (CASE WHEN coverArtData  IS NOT NULL THEN 1  ELSE 0 END)
                       + (CASE WHEN year          IS NOT NULL THEN 2  ELSE 0 END)
                       + (CASE WHEN genre         IS NOT NULL THEN 4  ELSE 0 END)
                       + (CASE WHEN musicBrainzID IS NOT NULL THEN 8  ELSE 0 END),
                       0, lastFetched, NULL, NULL
                FROM albumInfo
                """)

            try db.execute(sql: """
                INSERT OR IGNORE INTO enrichmentState
                    (scope, key, version, status, fields, attempts)
                SELECT 'artist',
                       flaccy_norm(name),
                       0,
                       CASE WHEN imageURL IS NOT NULL THEN 1 ELSE 0 END,
                         (CASE WHEN bio      IS NOT NULL THEN 16 ELSE 0 END)
                       + (CASE WHEN imageURL IS NOT NULL THEN 32 ELSE 0 END),
                       0
                FROM artists
                """)

            try db.execute(sql: """
                INSERT OR IGNORE INTO enrichmentState
                    (scope, key, version, status, fields, attempts)
                SELECT 'aiBatch',
                       flaccy_norm(rtrim(rtrim(fileURL, replace(fileURL, '/', '')), '/')),
                       0, 1, 64, 0
                FROM tracks
                WHERE aiAnalyzed = 1
                GROUP BY 2
                """)
        }

        migrator.registerMigration("v11") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "albumArtist", .text)
            }
        }

        migrator.registerMigration("v12") { db in
            try db.alter(table: "albumInfo") { t in
                t.add(column: "customCoverData", .blob)
            }
        }

        migrator.registerMigration("v13") { db in
            try db.alter(table: "playlists") { t in
                t.add(column: "customCoverData", .blob)
            }
        }

        migrator.registerMigration("v14") { db in
            try db.alter(table: "lyrics") { t in
                t.add(column: "lyricsfile", .text)
                t.add(column: "offsetMs", .integer).notNull().defaults(to: 0)
                t.add(column: "revision", .integer).notNull().defaults(to: 0)
            }
        }

        return migrator
    }
}
