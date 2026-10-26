//! Loves, ratings, scalars and sessions: one row per user and key.

use flaccy_server_core::apply::{Outcome, Status};
use rusqlite::Connection;

use super::changes;
use super::meta::Counters;
use super::rows::UserRow;
use super::SyncError;

/// Loads the user's row, lets `apply` change it, and on `applied` stores it and files the change under the user.
pub(super) fn apply_single<T: UserRow>(
    connection: &Connection,
    counters: &mut Counters,
    user: &str,
    key: &str,
    apply: impl FnOnce(&mut Option<T>) -> Outcome,
) -> Result<Outcome, SyncError> {
    let mut slot = T::load(connection, user, key)?;
    let outcome = apply(&mut slot);
    if outcome.status != Status::Applied {
        return Ok(outcome);
    }
    if let Some(value) = &slot {
        value.save(connection, user)?;
    }
    record_user_changes(connection, counters, user, &outcome)?;
    Ok(outcome)
}

/// Files every changed entity of `outcome` under the user's scope.
pub(super) fn record_user_changes(
    connection: &Connection,
    counters: &mut Counters,
    user: &str,
    outcome: &Outcome,
) -> Result<(), SyncError> {
    for reference in &outcome.changed {
        let seq = counters.next_seq();
        changes::record(connection, counters, user, reference.kind, &reference.id, seq)?;
    }
    Ok(())
}
