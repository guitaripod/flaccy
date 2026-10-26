//! The tables of `security.sqlite`, as PROTOCOL.md section 10.1 lists them.

use rusqlite::Transaction;

use crate::dbthread::Migration;

/// Every migration of `security.sqlite`, oldest first.
pub const MIGRATIONS: &[Migration] = &[Migration {
    version: 1,
    apply: create_tables,
}];

/// The schema version this build writes.
pub const CURRENT_VERSION: u32 = 1;

const TABLES: &str = "
CREATE TABLE users(
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    tailnet_user_id TEXT,
    login TEXT,
    role TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE devices(
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    name TEXT NOT NULL,
    platform TEXT NOT NULL,
    token_hash BLOB NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    last_seen_at INTEGER,
    revoked_at INTEGER
);
CREATE INDEX devices_user ON devices(user_id);
CREATE TABLE enrollments(
    code_hash BLOB PRIMARY KEY,
    user_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    used_at INTEGER
);
CREATE TABLE api_keys(
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    name TEXT NOT NULL,
    key_hash BLOB NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    revoked_at INTEGER
);
CREATE TABLE audit(
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    at INTEGER NOT NULL,
    actor TEXT,
    action TEXT NOT NULL,
    detail TEXT,
    prev_hash BLOB NOT NULL,
    hash BLOB NOT NULL
);
CREATE TABLE server_meta(
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE lastfm_sessions(
    user_id TEXT PRIMARY KEY,
    username TEXT NOT NULL,
    session_key TEXT NOT NULL
);
";

fn create_tables(step: &Transaction<'_>) -> rusqlite::Result<()> {
    step.execute_batch(TABLES)
}
