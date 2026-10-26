//! `GET /sync/pull`: PROTOCOL.md section 6.2.

use std::fmt;

use flaccy_server_core::wire::{Change, PullResponse};
use rusqlite::{Connection, OptionalExtension};

use super::changes::parse_kind;
use super::entity::{change_of, see};
use super::meta::global_seq;
use super::{Store, SyncError, HOUSEHOLD_SCOPE};
use crate::security::Principal;

/// The most changes one pull returns.
pub const MAX_PULL_LIMIT: usize = 5000;
/// The page size when the client names none.
pub const DEFAULT_PULL_LIMIT: usize = 1000;

/// Why a pull was refused.
#[derive(Debug)]
pub enum PullError {
    /// The client's incarnation is not the server's.
    IncarnationChanged {
        /// The server's incarnation.
        current: String,
    },
    /// The cursor is ahead of the server's log.
    CookieAhead {
        /// The server's incarnation.
        current: String,
    },
    /// The database failed.
    Storage(SyncError),
}

impl fmt::Display for PullError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PullError::IncarnationChanged { .. } => write!(
                formatter,
                "The server's state was replaced since this device last synced. Reseed from your base, start a new instance and pull again from zero."
            ),
            PullError::CookieAhead { .. } => write!(
                formatter,
                "This device's cursor is ahead of everything the server has, as after a restore from a backup. Reseed from your base, start a new instance and pull again from zero."
            ),
            PullError::Storage(source) => write!(formatter, "{source}"),
        }
    }
}

impl std::error::Error for PullError {}

impl From<SyncError> for PullError {
    fn from(source: SyncError) -> Self {
        PullError::Storage(source)
    }
}

impl From<rusqlite::Error> for PullError {
    fn from(source: rusqlite::Error) -> Self {
        PullError::Storage(source.into())
    }
}

fn scope_head(connection: &Connection, user: &str) -> Result<i64, SyncError> {
    let head: Option<i64> = connection
        .prepare_cached(
            "SELECT seq FROM changes INDEXED BY changes_seq WHERE scope IN (?1, ?2) ORDER BY seq DESC LIMIT 1",
        )?
        .query_row((user, HOUSEHOLD_SCOPE), |row| row.get(0))
        .optional()?;
    Ok(head.unwrap_or(0))
}

fn confirmed_mutation_id(connection: &Connection, device: &str, instance: &str) -> Result<i64, SyncError> {
    if device.is_empty() || instance.is_empty() {
        return Ok(0);
    }
    Ok(connection
        .prepare_cached("SELECT last_mutation_id FROM device_progress WHERE device_id = ?1 AND instance = ?2")?
        .query_row((device, instance), |row| row.get(0))
        .optional()?
        .unwrap_or(0))
}

fn due_rows(connection: &Connection, user: &str, since: i64, take: usize) -> Result<Vec<(String, String, i64)>, SyncError> {
    let mut statement = connection.prepare_cached(
        "SELECT kind, id, MAX(seq) FROM changes WHERE seq > ?1 AND scope IN (?2, ?3)
         GROUP BY kind, id ORDER BY MAX(seq) LIMIT ?4",
    )?;
    let rows = statement
        .query_map((since, user, HOUSEHOLD_SCOPE, take as i64), |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

fn changes_of(connection: &Connection, user: &str, rows: Vec<(String, String, i64)>) -> Result<Vec<Change>, SyncError> {
    let mut changes = Vec::with_capacity(rows.len());
    for (kind, id, seq) in rows {
        let Some(kind) = parse_kind(&kind) else {
            return Err(SyncError::Corrupt(format!("changes holds the kind '{kind}'")));
        };
        if let Some(seen) = see(connection, user, kind, &id)? {
            changes.push(change_of(seq, seen.into_sent()));
        }
    }
    Ok(changes)
}

impl Store {
    /// The changes after `since` for `principal`'s user and the household, ascending, at most `limit`.
    ///
    /// `instance` names the push instance whose confirmed mutation id the answer carries (empty: 0). The changes,
    /// the head and that id are read in one snapshot.
    pub async fn pull(
        &self,
        principal: &Principal,
        instance: &str,
        since: i64,
        limit: usize,
        claimed_incarnation: Option<&str>,
    ) -> Result<PullResponse, PullError> {
        let current = self.incarnation();
        if self.check_incarnation(claimed_incarnation).is_some() {
            return Err(PullError::IncarnationChanged { current });
        }
        let user = principal.user.to_string();
        let device = principal.device.as_ref().map(|device| device.to_string()).unwrap_or_default();
        let instance = instance.to_owned();
        let limit = limit.clamp(1, MAX_PULL_LIMIT);
        let now_ms = self.now_ms();
        self.read(move |connection| {
            let snapshot = connection.unchecked_transaction()?;
            if since > global_seq(&snapshot)? {
                return Err(PullError::CookieAhead { current });
            }
            let head = scope_head(&snapshot, &user)?;
            let last_mutation_id = confirmed_mutation_id(&snapshot, &device, &instance)?;
            let mut rows = due_rows(&snapshot, &user, since, limit + 1)?;
            let more = rows.len() > limit;
            rows.truncate(limit);
            let changes = changes_of(&snapshot, &user, rows)?;
            Ok(PullResponse {
                head,
                incarnation: current,
                last_mutation_id,
                more,
                server_time_ms: now_ms,
                changes,
            })
        })
        .await
    }
}
