use crate::oracle::{Oracle, Row};
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;
use std::time::Duration;

/// Watches one client's pending table: a row that appears was issued, a row that disappears was retired by a pull.
#[derive(Default)]
pub struct Tracker {
    known: BTreeMap<i64, Row>,
}

impl Tracker {
    /// Compares the queue with the last look and tells `oracle` what changed.
    pub fn observe(&mut self, database: &Path, oracle: &mut Oracle) -> Result<(), String> {
        let rows = read_pending(database)?;
        let mut now = BTreeMap::new();
        for row in rows {
            if !self.known.contains_key(&row.stamp) {
                oracle.note_issued(&row);
            }
            now.insert(row.stamp, row);
        }
        for (stamp, row) in &self.known {
            if !now.contains_key(stamp) {
                oracle.note_retired(row);
            }
        }
        self.known = now;
        Ok(())
    }

    /// Forgets the old queue after a reinstall or a restore, then adopts the new database's.
    pub fn restart(&mut self, database: &Path, oracle: &mut Oracle) -> Result<(), String> {
        self.known.clear();
        self.observe(database, oracle)
    }

    /// Mutations still queued as of the last look.
    pub fn queued(&self) -> usize {
        self.known.len()
    }
}

fn read_pending(database: &Path) -> Result<Vec<Row>, String> {
    let connection = Connection::open_with_flags(database, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|error| format!("cannot read the queue of {}: {error}", database.display()))?;
    connection
        .busy_timeout(Duration::from_secs(10))
        .map_err(|error| format!("busy timeout: {error}"))?;
    let mut statement = connection
        .prepare("SELECT stamp, name, args_json, failed FROM sync_pending ORDER BY mutation_id")
        .map_err(|error| format!("cannot query the queue: {error}"))?;
    let rows = statement
        .query_map([], |row| {
            let args: String = row.get(2)?;
            Ok(Row {
                stamp: row.get(0)?,
                name: row.get(1)?,
                args: serde_json::from_str::<Value>(&args).unwrap_or(Value::Null),
                failed: row.get::<_, i64>(3)? != 0,
            })
        })
        .map_err(|error| format!("cannot read the queue: {error}"))?;
    rows.collect::<Result<Vec<_>, _>>().map_err(|error| format!("cannot read a queue row: {error}"))
}
