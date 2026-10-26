//! The history sync's rows in `state.sqlite`: which Last.fm account each user has, and where the planner stands.

use flaccy_library::listen_history::HistorySyncState;
use rusqlite::{OptionalExtension, Row};

use crate::security::UserId;
use crate::sync::{Store, SyncError};

/// The scalar a user's Last.fm account name lives in.
pub const ACCOUNT_KEY: &str = "lastfm/account";

/// What the worker is doing for a user.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// Nothing under way; the last pull finished.
    Idle,
    /// The first full pull.
    Backfilling,
    /// A catch-up or settle pull.
    Syncing,
    /// The last attempt failed; see the error.
    Failed,
}

impl Phase {
    /// The word stored and shown.
    pub fn word(self) -> &'static str {
        match self {
            Phase::Idle => "idle",
            Phase::Backfilling => "backfilling",
            Phase::Syncing => "syncing",
            Phase::Failed => "failed",
        }
    }

    fn parse(word: &str) -> Phase {
        match word {
            "backfilling" => Phase::Backfilling,
            "syncing" => Phase::Syncing,
            "failed" => Phase::Failed,
            _ => Phase::Idle,
        }
    }
}

/// A user's history sync as stored.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncRecord {
    /// The planner's state: anchor, page, newest play, last catch-up and settle.
    pub plan: HistorySyncState,
    /// The page count Last.fm reported for the first full pull.
    pub total_pages: u32,
    /// Plays stored by this sync so far.
    pub stored: i64,
    /// What the worker is doing.
    pub phase: Phase,
    /// The sentence a person reads when the last attempt failed.
    pub last_error: Option<String>,
    /// Unix seconds before which the worker does not try again.
    pub retry_at: Option<i64>,
    /// Unix seconds of the last write.
    pub updated_at: i64,
}

impl SyncRecord {
    /// A fresh record for `account`, nothing pulled yet.
    pub fn fresh(account: &str, now: i64) -> Self {
        Self {
            plan: HistorySyncState::default().for_account(account),
            total_pages: 0,
            stored: 0,
            phase: Phase::Idle,
            last_error: None,
            retry_at: None,
            updated_at: now,
        }
    }
}

const COLUMNS: &str = "account, anchor, cursor, backfilled_through, last_catchup, last_settle, complete, total_pages, stored, phase, last_error, retry_at, updated_at";

fn record_from_row(row: &Row<'_>) -> rusqlite::Result<SyncRecord> {
    let phase: String = row.get(9)?;
    Ok(SyncRecord {
        plan: HistorySyncState {
            account: row.get(0)?,
            backfill_anchor: row.get(1)?,
            backfill_page: row.get(2)?,
            newest_remote: row.get(3)?,
            last_sync_at: row.get(4)?,
            last_settle_at: row.get(5)?,
            backfill_complete: row.get(6)?,
        },
        total_pages: row.get(7)?,
        stored: row.get(8)?,
        phase: Phase::parse(&phase),
        last_error: row.get(10)?,
        retry_at: row.get(11)?,
        updated_at: row.get(12)?,
    })
}

impl Store {
    /// Every user who has a Last.fm account name set, with that name.
    pub async fn lastfm_accounts(&self) -> Result<Vec<(UserId, String)>, SyncError> {
        self.read(|connection| {
            let mut statement = connection.prepare_cached("SELECT user_id, value_json FROM scalars WHERE key = ?1 AND deleted = 0 ORDER BY user_id")?;
            let rows = statement
                .query_map([ACCOUNT_KEY], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
                .collect::<Result<Vec<_>, _>>()?;
            Ok::<_, SyncError>(
                rows.into_iter()
                    .filter_map(|(user, json)| {
                        let name = serde_json::from_str::<String>(&json).ok()?;
                        let name = name.trim().to_owned();
                        (!name.is_empty()).then_some((UserId(user), name))
                    })
                    .collect(),
            )
        })
        .await
    }

    /// The history sync of `user`, `None` before the first attempt.
    pub async fn lastfm_sync_record(&self, user: &UserId) -> Result<Option<SyncRecord>, SyncError> {
        let user = user.to_string();
        self.read(move |connection| {
            Ok::<_, SyncError>(
                connection
                    .prepare_cached(&format!("SELECT {COLUMNS} FROM lastfm_sync WHERE user_id = ?1"))?
                    .query_row([&user], record_from_row)
                    .optional()?,
            )
        })
        .await
    }

    /// Stores `record` as the history sync of `user`.
    pub async fn save_lastfm_sync(&self, user: &UserId, record: &SyncRecord) -> Result<(), SyncError> {
        let user = user.to_string();
        let record = record.clone();
        self.write(move |connection| {
            connection
                .prepare_cached(&format!(
                    "INSERT OR REPLACE INTO lastfm_sync(user_id, {COLUMNS}) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)"
                ))?
                .execute((
                    &user,
                    &record.plan.account,
                    record.plan.backfill_anchor,
                    record.plan.backfill_page,
                    record.plan.newest_remote,
                    record.plan.last_sync_at,
                    record.plan.last_settle_at,
                    record.plan.backfill_complete,
                    record.total_pages,
                    record.stored,
                    record.phase.word(),
                    &record.last_error,
                    record.retry_at,
                    record.updated_at,
                ))?;
            Ok::<_, SyncError>(())
        })
        .await
    }

    /// Whether the server is bringing in `user`'s history, which is what `/hello` tells that user's clients.
    pub async fn lastfm_history_flowing(&self, user: &UserId) -> Result<bool, SyncError> {
        Ok(self.lastfm_sync_record(user).await?.is_some_and(|record| {
            record.plan.backfill_complete || (record.phase != Phase::Failed && (record.stored > 0 || record.plan.last_sync_at.is_some()))
        }))
    }
}
