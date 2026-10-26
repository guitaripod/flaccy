import GRDB

/// The tables and columns Flaccy Server sync adds to the library database (migration v18).
enum ServerSyncSchema {

    static let tables = [
        "sync_pending", "sync_base", "sync_ghosts", "sync_blobs", "sync_song_keys", "sync_meta",
    ]

    static func create(_ db: Database) throws {
        try db.alter(table: "playlists") { t in
            t.add(column: "syncId", .text)
        }
        try db.alter(table: "playlistTracks") { t in
            t.add(column: "syncId", .text)
        }
        try db.alter(table: "scrobbles") { t in
            t.add(column: "eventId", .text)
            t.add(column: "suppressed", .integer).notNull().defaults(to: 0)
        }
        try db.execute(sql: """
            CREATE UNIQUE INDEX playlists_on_syncId ON playlists(syncId) WHERE syncId IS NOT NULL;
            CREATE UNIQUE INDEX playlistTracks_on_syncId ON playlistTracks(syncId) WHERE syncId IS NOT NULL;
            CREATE UNIQUE INDEX scrobbles_on_eventId ON scrobbles(eventId) WHERE eventId IS NOT NULL;
            CREATE INDEX scrobbles_on_live_timestamp ON scrobbles(timestamp) WHERE suppressed = 0;
            CREATE INDEX tracks_on_audioFingerprint ON tracks(audioFingerprint) WHERE audioFingerprint IS NOT NULL;
            CREATE INDEX tracks_on_musicBrainzID ON tracks(musicBrainzID) WHERE musicBrainzID IS NOT NULL;

            CREATE TABLE sync_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE sync_base (
                kind TEXT NOT NULL,
                id TEXT NOT NULL,
                parent TEXT,
                value_json TEXT NOT NULL,
                deleted INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (kind, id)
            ) WITHOUT ROWID;
            CREATE INDEX sync_base_on_parent ON sync_base(kind, parent);

            CREATE TABLE sync_pending (
                mutation_id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                stamp INTEGER NOT NULL,
                args_json TEXT NOT NULL,
                acked INTEGER NOT NULL DEFAULT 0,
                failed INTEGER NOT NULL DEFAULT 0,
                sent INTEGER NOT NULL DEFAULT 0,
                touches_json TEXT NOT NULL DEFAULT '[]'
            );

            CREATE TABLE sync_ghosts (
                kind TEXT NOT NULL,
                id TEXT NOT NULL,
                value_json TEXT NOT NULL,
                PRIMARY KEY (kind, id)
            ) WITHOUT ROWID;

            CREATE TABLE sync_blobs (
                hash TEXT PRIMARY KEY,
                data BLOB NOT NULL
            ) WITHOUT ROWID;

            CREATE TABLE sync_song_keys (
                trackId INTEGER PRIMARY KEY,
                title TEXT NOT NULL,
                artist TEXT NOT NULL,
                songKey TEXT NOT NULL
            );
            CREATE INDEX sync_song_keys_on_songKey ON sync_song_keys(songKey);
            """)
    }
}
