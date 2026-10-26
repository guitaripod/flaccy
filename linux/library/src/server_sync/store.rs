use super::error::{db_error, Result};
use super::recorder::Recorder;
use rusqlite::Connection;

/// Runs `work` as one atomic unit: its own `BEGIN IMMEDIATE` transaction when
/// the connection is idle, a savepoint when the caller already holds a
/// transaction. A failure undoes everything `work` wrote.
pub(crate) fn atomically<T>(conn: &Connection, work: impl FnOnce() -> Result<T>) -> Result<T> {
    let (begin, commit, rollback) = if conn.is_autocommit() {
        ("BEGIN IMMEDIATE", "COMMIT", "ROLLBACK")
    } else {
        (
            "SAVEPOINT fsync",
            "RELEASE fsync",
            "ROLLBACK TO fsync; RELEASE fsync",
        )
    };
    conn.execute_batch(begin)?;
    match work() {
        Ok(value) => match conn.execute_batch(commit) {
            Ok(()) => Ok(value),
            Err(error) => {
                let _ = conn.execute_batch(rollback);
                Err(error.into())
            }
        },
        Err(error) => {
            let _ = conn.execute_batch(rollback);
            Err(error)
        }
    }
}

/// Runs an app-table write together with its recording as one atomic unit.
///
/// The recorder inside `work` queues the mutation in the same transaction, so a
/// visible change never exists without it. With no server configured the
/// recorder does nothing and this is an ordinary transaction.
pub(crate) fn record<T>(
    conn: &Connection,
    work: impl FnOnce(&Recorder) -> Result<T>,
) -> rusqlite::Result<T> {
    let recorder = Recorder::new(conn);
    atomically(conn, || work(&recorder)).map_err(db_error)
}
