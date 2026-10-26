//! Counts for `flaccy-server status`.

use super::meta::global_seq;
use super::{Store, SyncError};

/// What the sync store holds.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncStats {
    /// The highest change sequence number assigned.
    pub head: i64,
    /// Playlists, dead ones included.
    pub playlists: i64,
    /// Playlist entries, dead ones included.
    pub entries: i64,
    /// Listens, suppressed ones included.
    pub listens: i64,
    /// Bytes `state.sqlite` and its write-ahead log occupy.
    pub bytes: u64,
}

fn count(connection: &rusqlite::Connection, table: &str) -> Result<i64, SyncError> {
    Ok(connection.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| row.get(0))?)
}

fn file_bytes(path: &std::path::Path) -> u64 {
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    ["", "-wal"]
        .iter()
        .filter_map(|suffix| std::fs::metadata(path.with_file_name(format!("{name}{suffix}"))).ok())
        .map(|metadata| metadata.len())
        .sum()
}

impl Store {
    /// Counts the stored entities.
    pub async fn stats(&self) -> Result<SyncStats, SyncError> {
        let bytes = file_bytes(self.file());
        self.read(move |connection| {
            Ok::<_, SyncError>(SyncStats {
                head: global_seq(connection)?,
                playlists: count(connection, "playlists")?,
                entries: count(connection, "playlist_entries")?,
                listens: count(connection, "listens")?,
                bytes,
            })
        })
        .await
    }
}
