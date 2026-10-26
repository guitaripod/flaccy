use rusqlite::{params, Connection};

const TABLES: &str = "
    CREATE TABLE IF NOT EXISTS sync_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS sync_base (
        kind TEXT NOT NULL,
        id TEXT NOT NULL,
        parent TEXT,
        value_json TEXT NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (kind, id)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS sync_base_on_parent ON sync_base(kind, parent);
    CREATE TABLE IF NOT EXISTS sync_pending (
        mutation_id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        stamp INTEGER NOT NULL,
        args_json TEXT NOT NULL,
        acked INTEGER NOT NULL DEFAULT 0,
        failed INTEGER NOT NULL DEFAULT 0,
        sent INTEGER NOT NULL DEFAULT 0,
        touches_json TEXT NOT NULL DEFAULT '[]'
    );
    CREATE TABLE IF NOT EXISTS sync_ghosts (
        kind TEXT NOT NULL,
        id TEXT NOT NULL,
        value_json TEXT NOT NULL,
        PRIMARY KEY (kind, id)
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS sync_song_keys (
        trackId INTEGER PRIMARY KEY,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        songKey TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS sync_song_keys_on_songKey ON sync_song_keys(songKey);
    CREATE UNIQUE INDEX IF NOT EXISTS playlists_on_syncId
        ON playlists(syncId) WHERE syncId IS NOT NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS playlistTracks_on_syncId
        ON playlistTracks(syncId) WHERE syncId IS NOT NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS scrobbles_on_eventId
        ON scrobbles(eventId) WHERE eventId IS NOT NULL;
    CREATE INDEX IF NOT EXISTS tracks_on_audioFingerprint
        ON tracks(audioFingerprint) WHERE audioFingerprint IS NOT NULL;
    CREATE INDEX IF NOT EXISTS tracks_on_musicBrainzID
        ON tracks(musicBrainzID) WHERE musicBrainzID IS NOT NULL;";

const COLUMNS: [(&str, &str); 4] = [
    ("playlists", "syncId TEXT"),
    ("playlistTracks", "syncId TEXT"),
    ("scrobbles", "eventId TEXT"),
    ("scrobbles", "suppressed INTEGER NOT NULL DEFAULT 0"),
];

/// Adds the sync columns, tables and indexes. Safe to run on every open: a
/// column that exists is left alone, a table or index that exists is kept.
pub(crate) fn migrate(conn: &Connection) -> rusqlite::Result<()> {
    for (table, definition) in COLUMNS {
        add_column(conn, table, definition)?;
    }
    conn.execute_batch(TABLES)
}

fn add_column(conn: &Connection, table: &str, definition: &str) -> rusqlite::Result<()> {
    let name = definition.split_whitespace().next().unwrap_or_default();
    if has_column(conn, table, name)? {
        return Ok(());
    }
    conn.execute(&format!("ALTER TABLE {table} ADD COLUMN {definition}"), [])?;
    Ok(())
}

fn has_column(conn: &Connection, table: &str, column: &str) -> rusqlite::Result<bool> {
    conn.query_row(
        "SELECT EXISTS (SELECT 1 FROM pragma_table_info(?1) WHERE name = ?2)",
        params![table, column],
        |row| row.get(0),
    )
}
