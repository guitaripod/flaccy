//! The Last.fm tables of `state.sqlite` (migration 2): the history planner's state and the scrobble relay's queue.

use rusqlite::Transaction;

const TABLES: &str = "
CREATE TABLE lastfm_sync(
    user_id TEXT PRIMARY KEY,
    account TEXT NOT NULL,
    anchor INTEGER,
    cursor INTEGER NOT NULL DEFAULT 1,
    backfilled_through INTEGER,
    last_catchup INTEGER,
    last_settle INTEGER,
    complete INTEGER NOT NULL DEFAULT 0,
    total_pages INTEGER NOT NULL DEFAULT 0,
    stored INTEGER NOT NULL DEFAULT 0,
    phase TEXT NOT NULL DEFAULT 'idle',
    last_error TEXT,
    retry_at INTEGER,
    updated_at INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE lastfm_relay(
    user_id TEXT PRIMARY KEY,
    connected_seq INTEGER NOT NULL,
    enqueued_seq INTEGER NOT NULL,
    connected_at INTEGER NOT NULL,
    paused_reason TEXT,
    paused_at INTEGER,
    last_submit INTEGER,
    last_error TEXT,
    submitted INTEGER NOT NULL DEFAULT 0,
    rejected INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE lastfm_queue(
    event_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    ts INTEGER NOT NULL,
    title TEXT NOT NULL,
    artist TEXT NOT NULL,
    album TEXT NOT NULL,
    duration_s INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    done_at INTEGER
);
CREATE INDEX lastfm_queue_due ON lastfm_queue(user_id, done_at, next_attempt_at, ts);
";

/// Migration 2 of `state.sqlite`.
pub fn create_tables(step: &Transaction<'_>) -> rusqlite::Result<()> {
    step.execute_batch(TABLES)
}
