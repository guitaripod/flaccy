//! Housekeeping of `security.sqlite`: an empty write-ahead log and fresh planner statistics.

use super::{SecurityError, Store};

impl Store {
    /// Empties the write-ahead log and refreshes the query planner's statistics.
    pub async fn tidy(&self) -> Result<(), SecurityError> {
        self.db
            .call(|connection| {
                connection.execute_batch("PRAGMA optimize")?;
                connection.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()))
            })
            .await?;
        Ok(())
    }
}
