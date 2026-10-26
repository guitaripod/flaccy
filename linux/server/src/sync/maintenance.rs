//! Housekeeping of `state.sqlite`: old mutation results go, and the write-ahead log stays small.

use rusqlite::Connection;

use super::{Store, SyncError};

/// The most `mutation_results` rows kept per device.
pub const KEEP_PER_DEVICE: i64 = 1000;
/// Rows older than this many days go, whatever the count.
pub const KEEP_DAYS: i64 = 30;

const MILLIS_PER_DAY: i64 = 24 * 60 * 60 * 1000;

const DELETE_OLD: &str = "DELETE FROM mutation_results WHERE at < ?1";
const DELETE_BEYOND_NEWEST: &str = "
DELETE FROM mutation_results WHERE rowid IN (
    SELECT rowid FROM (
        SELECT rowid, ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY at DESC, instance DESC, id DESC) AS newest
        FROM mutation_results
    ) WHERE newest > ?1
)";

/// What one pass of housekeeping removed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Tidied {
    /// `mutation_results` rows deleted.
    pub results_pruned: usize,
}

fn prune(connection: &Connection, now_ms: i64) -> Result<usize, SyncError> {
    let cutoff = now_ms - KEEP_DAYS * MILLIS_PER_DAY;
    let old = connection.execute(DELETE_OLD, [cutoff])?;
    let surplus = connection.execute(DELETE_BEYOND_NEWEST, [KEEP_PER_DEVICE])?;
    Ok(old + surplus)
}

fn shrink_log(connection: &Connection) -> Result<(), SyncError> {
    connection.execute_batch("PRAGMA optimize")?;
    connection.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()))?;
    Ok(())
}

impl Store {
    /// Deletes the results of mutations older than 30 days and all but the newest 1,000 of each device.
    ///
    /// A retry of a pruned mutation id is then answered `409 instance_conflict`, which makes the client move to a
    /// new instance; no client holds a mutation for that long.
    pub async fn prune_mutation_results(&self) -> Result<usize, SyncError> {
        let now_ms = self.now_ms();
        self.write(move |connection| prune(connection, now_ms)).await
    }

    /// Prunes, then empties the write-ahead log and refreshes the query planner's statistics.
    pub async fn tidy(&self) -> Result<Tidied, SyncError> {
        let now_ms = self.now_ms();
        self.write(move |connection| {
            let results_pruned = prune(connection, now_ms)?;
            shrink_log(connection)?;
            Ok::<_, SyncError>(Tidied { results_pruned })
        })
        .await
    }
}
