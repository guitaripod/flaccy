//! The audit trail: an append-only chain where every entry commits to the one before it.
//!
//! `hash = SHA-256(prev_hash || at || actor || action || detail)`, each field
//! followed by a zero byte so no two entries can hash alike by moving text
//! between fields. The first entry's `prev_hash` is 32 zero bytes. Editing or
//! deleting any entry but the newest breaks the chain at the next entry.

use std::fmt;

use rusqlite::{Connection, OptionalExtension};
use sha2::{Digest, Sha256};

use super::{SecurityError, Store};

const HASH_BYTES: usize = 32;
const GENESIS: [u8; HASH_BYTES] = [0u8; HASH_BYTES];

/// Why the audit chain could not be confirmed.
#[derive(Debug)]
pub enum VerifyError {
    /// The entry with this `seq` does not match what comes before it.
    BrokenAt(i64),
    /// The database failed before the chain could be checked.
    Storage(SecurityError),
}

impl fmt::Display for VerifyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            VerifyError::BrokenAt(seq) => write!(
                formatter,
                "The audit trail is broken at entry {seq}: it was edited or an earlier entry was removed. Restore security.sqlite from a backup taken before then, and look at who could write to the data folder."
            ),
            VerifyError::Storage(source) => write!(formatter, "{source}"),
        }
    }
}

impl std::error::Error for VerifyError {}

fn entry_hash(prev_hash: &[u8], at: i64, actor: Option<&str>, action: &str, detail: Option<&str>) -> [u8; HASH_BYTES] {
    let mut hasher = Sha256::new();
    hasher.update(prev_hash);
    hasher.update(at.to_string().as_bytes());
    for field in [actor.unwrap_or(""), action, detail.unwrap_or("")] {
        hasher.update([0u8]);
        hasher.update(field.as_bytes());
    }
    hasher.finalize().into()
}

/// Appends an entry to the chain through `connection`, which should be inside the transaction of the change it records.
pub fn append(connection: &Connection, at: i64, actor: Option<&str>, action: &str, detail: &str) -> rusqlite::Result<()> {
    let prev_hash: Vec<u8> = connection
        .query_row("SELECT hash FROM audit ORDER BY seq DESC LIMIT 1", [], |row| row.get(0))
        .optional()?
        .unwrap_or_else(|| GENESIS.to_vec());
    let hash = entry_hash(&prev_hash, at, actor, action, Some(detail));
    connection.execute(
        "INSERT INTO audit(at, actor, action, detail, prev_hash, hash) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        (at, actor, action, detail, prev_hash.as_slice(), hash.as_slice()),
    )?;
    Ok(())
}

/// Walks the whole chain from the first entry and reports the first entry that does not fit.
pub fn verify(connection: &Connection) -> Result<(), VerifyError> {
    let storage = |source: rusqlite::Error| VerifyError::Storage(source.into());
    let mut statement = connection
        .prepare("SELECT seq, at, actor, action, detail, prev_hash, hash FROM audit ORDER BY seq")
        .map_err(storage)?;
    let mut rows = statement.query([]).map_err(storage)?;
    let mut expected_prev = GENESIS.to_vec();
    while let Some(row) = rows.next().map_err(storage)? {
        let seq: i64 = row.get(0).map_err(storage)?;
        let at: i64 = row.get(1).map_err(storage)?;
        let actor: Option<String> = row.get(2).map_err(storage)?;
        let action: String = row.get(3).map_err(storage)?;
        let detail: Option<String> = row.get(4).map_err(storage)?;
        let prev_hash: Vec<u8> = row.get(5).map_err(storage)?;
        let hash: Vec<u8> = row.get(6).map_err(storage)?;
        let recomputed = entry_hash(&prev_hash, at, actor.as_deref(), &action, detail.as_deref());
        if prev_hash != expected_prev || hash.as_slice() != recomputed.as_slice() {
            return Err(VerifyError::BrokenAt(seq));
        }
        expected_prev = hash;
    }
    Ok(())
}

impl Store {
    /// Checks the whole audit chain.
    pub async fn verify_audit(&self) -> Result<(), VerifyError> {
        match self.read(|connection| Ok(verify(connection))).await {
            Ok(outcome) => outcome,
            Err(error) => Err(VerifyError::Storage(error)),
        }
    }

    /// The number of audit entries.
    pub async fn audit_len(&self) -> Result<u64, SecurityError> {
        self.read(|connection| Ok(connection.query_row("SELECT COUNT(*) FROM audit", [], |row| row.get(0))?)).await
    }
}
