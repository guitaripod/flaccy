//! The tables of `state.sqlite`, as PROTOCOL.md section 10.2 lists them.

use rusqlite::Transaction;

use crate::dbthread::Migration;

/// Every migration of `state.sqlite`, oldest first.
pub const MIGRATIONS: &[Migration] = &[Migration {
    version: 1,
    apply: create_tables,
}];

/// The schema version this build writes.
pub const CURRENT_VERSION: u32 = 1;

const TABLES: &str = "
CREATE TABLE server_meta(
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE changes(
    seq INTEGER NOT NULL,
    scope TEXT NOT NULL,
    kind TEXT NOT NULL,
    id TEXT NOT NULL,
    PRIMARY KEY(scope, kind, id)
);
CREATE INDEX changes_seq ON changes(seq);
CREATE TABLE playlists(
    id TEXT PRIMARY KEY,
    owner TEXT NOT NULL,
    name TEXT NOT NULL,
    cover_blob TEXT,
    visibility TEXT NOT NULL,
    alive INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    st_name INTEGER NOT NULL,
    st_cover INTEGER NOT NULL,
    st_visibility INTEGER NOT NULL,
    st_alive INTEGER NOT NULL
);
CREATE TABLE playlist_entries(
    id TEXT PRIMARY KEY,
    playlist_id TEXT NOT NULL,
    ref_json TEXT NOT NULL,
    pos TEXT NOT NULL,
    alive INTEGER NOT NULL,
    st_ref INTEGER NOT NULL,
    st_pos INTEGER NOT NULL,
    st_alive INTEGER NOT NULL
);
CREATE INDEX entries_playlist ON playlist_entries(playlist_id, pos, id);
CREATE TABLE loves(
    user_id TEXT NOT NULL,
    song_key TEXT NOT NULL,
    ref_json TEXT NOT NULL,
    loved INTEGER NOT NULL,
    stamp INTEGER NOT NULL,
    PRIMARY KEY(user_id, song_key)
);
CREATE TABLE ratings(
    user_id TEXT NOT NULL,
    song_key TEXT NOT NULL,
    ref_json TEXT NOT NULL,
    rating INTEGER,
    stamp INTEGER NOT NULL,
    PRIMARY KEY(user_id, song_key)
);
CREATE TABLE scalars(
    user_id TEXT NOT NULL,
    key TEXT NOT NULL,
    value_json TEXT NOT NULL,
    deleted INTEGER NOT NULL,
    stamp INTEGER NOT NULL,
    PRIMARY KEY(user_id, key)
);
CREATE TABLE sessions(
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    session_json TEXT NOT NULL,
    stamp INTEGER NOT NULL,
    PRIMARY KEY(user_id, device_id)
);
CREATE TABLE listens(
    event_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    ts INTEGER NOT NULL,
    song_key TEXT NOT NULL,
    title_key TEXT NOT NULL,
    artist_key TEXT NOT NULL,
    ref_json TEXT NOT NULL,
    played_s INTEGER NOT NULL,
    source TEXT NOT NULL,
    recorded INTEGER NOT NULL,
    device_id TEXT,
    suppressed INTEGER NOT NULL,
    seq INTEGER NOT NULL
);
CREATE INDEX listens_user_ts ON listens(user_id, ts);
CREATE INDEX listens_user_seq ON listens(user_id, seq);
CREATE INDEX listens_user_song_ts ON listens(user_id, song_key, ts);
CREATE TABLE device_progress(
    device_id TEXT NOT NULL,
    instance TEXT NOT NULL,
    last_mutation_id INTEGER NOT NULL,
    PRIMARY KEY(device_id, instance)
);
CREATE TABLE mutation_results(
    device_id TEXT NOT NULL,
    instance TEXT NOT NULL,
    id INTEGER NOT NULL,
    arg_hash BLOB NOT NULL,
    status TEXT NOT NULL,
    code TEXT,
    at INTEGER NOT NULL,
    PRIMARY KEY(device_id, instance, id)
);
CREATE TABLE blobs(
    hash TEXT PRIMARY KEY,
    mime TEXT NOT NULL,
    size INTEGER NOT NULL,
    data BLOB NOT NULL
);
";

fn create_tables(step: &Transaction<'_>) -> rusqlite::Result<()> {
    step.execute_batch(TABLES)
}
