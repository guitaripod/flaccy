//! The counters in `server_meta`: the change sequence and the server's hybrid clock.

use std::collections::BTreeMap;

use flaccy_server_core::stamp::{ServerClock, Stamp};
use rusqlite::{Connection, OptionalExtension};

use super::{Poke, SyncError};

const SEQ_KEY: &str = "seq";
const CLOCK_KEY: &str = "server_hlc";
const SCHEMA_KEY: &str = "schema";

/// Gives the counters their first values and records the schema version.
pub(super) fn seed(connection: &Connection, version: u32) -> Result<(), SyncError> {
    for key in [SEQ_KEY, CLOCK_KEY] {
        connection.execute("INSERT OR IGNORE INTO server_meta(key, value) VALUES (?1, '0')", [key])?;
    }
    connection.execute(
        "INSERT INTO server_meta(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (SCHEMA_KEY, version.to_string()),
    )?;
    Ok(())
}

fn read_number(connection: &Connection, key: &str) -> Result<i64, SyncError> {
    let text: Option<String> = connection
        .prepare_cached("SELECT value FROM server_meta WHERE key = ?1")?
        .query_row([key], |row| row.get(0))
        .optional()?;
    match text {
        Some(text) => text.parse().map_err(|_| SyncError::Corrupt(format!("server_meta {key} is not a number"))),
        None => Ok(0),
    }
}

fn write_number(connection: &Connection, key: &str, value: i64) -> Result<(), SyncError> {
    connection
        .prepare_cached("UPDATE server_meta SET value = ?1 WHERE key = ?2")?
        .execute((value.to_string(), key))?;
    Ok(())
}

/// The highest change sequence number ever assigned.
pub(super) fn global_seq(connection: &Connection) -> Result<i64, SyncError> {
    read_number(connection, SEQ_KEY)
}

/// The sequence counter and clock a push works with, saved with every mutation it applies.
pub(super) struct Counters {
    seq: i64,
    pub clock: ServerClock,
    heads: BTreeMap<String, i64>,
    renames: Vec<(String, String)>,
}

impl Counters {
    /// Reads the counters as the last commit left them.
    pub fn load(connection: &Connection) -> Result<Self, SyncError> {
        Ok(Self {
            seq: read_number(connection, SEQ_KEY)?,
            clock: ServerClock::new(Stamp(read_number(connection, CLOCK_KEY)?)),
            heads: BTreeMap::new(),
            renames: Vec::new(),
        })
    }

    /// Writes both counters; call it inside the transaction of the mutation that moved them.
    pub fn save(&self, connection: &Connection) -> Result<(), SyncError> {
        write_number(connection, SEQ_KEY, self.seq)?;
        write_number(connection, CLOCK_KEY, self.clock.last().0)
    }

    /// A new, never used sequence number.
    pub fn next_seq(&mut self) -> i64 {
        self.seq += 1;
        self.seq
    }

    /// Remembers that `seq` was assigned in `scope`, for the poke after the commit.
    pub fn note_head(&mut self, scope: &str, seq: i64) {
        let head = self.heads.entry(scope.to_owned()).or_insert(seq);
        *head = (*head).max(seq);
    }

    /// Remembers a device rename to hand over once the commit has landed.
    pub fn note_rename(&mut self, device: &str, name: &str) {
        self.renames.push((device.to_owned(), name.to_owned()));
    }

    /// The pokes and renames of the commit that just landed; forgets them.
    pub fn take_effects(&mut self) -> (Vec<Poke>, Vec<(String, String)>) {
        let pokes = std::mem::take(&mut self.heads)
            .into_iter()
            .map(|(scope, head)| Poke { scope, head })
            .collect();
        (pokes, std::mem::take(&mut self.renames))
    }
}
