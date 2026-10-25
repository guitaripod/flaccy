//! The server's own tables and queries.
//!
//! The library schema belongs to `flaccy-library`. What only a server needs, a
//! rating per song, the one saved play queue and a little bookkeeping, lives in
//! tables created here, in the same database file, through a connection of the
//! server's own so the library crate stays untouched.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

/// The saved play queue as stored: song ids in order, which one plays and where.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct QueueRecord {
    pub entries: Vec<String>,
    pub current: Option<String>,
    pub position: i64,
    pub changed_by: String,
    #[serde(skip)]
    pub changed_at: String,
}

/// Columns of a track row the library crate's own row type leaves out.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TrackExtra {
    pub size: Option<i64>,
    pub fingerprint: Option<String>,
    pub musicbrainz_id: Option<String>,
}

/// A connection to the library database for the tables and queries a server adds.
pub struct Store {
    connection: Mutex<Connection>,
}

impl Store {
    /// Opens the database at `path`, which `Db::open` must already have migrated,
    /// and creates the server's tables.
    pub fn open(path: &Path) -> Result<Self, String> {
        let describe = |step: &str, err: rusqlite::Error| {
            format!(
                "Could not {step} the library database at {}: {err}. Check that the data folder is writable and that no other program holds the file, then start the server again.",
                path.display()
            )
        };
        let connection = Connection::open(path).map_err(|err| describe("open", err))?;
        let _ = connection.busy_timeout(std::time::Duration::from_secs(5));
        let _ = connection.pragma_update(None, "journal_mode", "WAL");
        connection
            .execute_batch(
                "CREATE TABLE IF NOT EXISTS ratings (
                    trackFileURL TEXT PRIMARY KEY,
                    rating INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS playQueue (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    json TEXT NOT NULL,
                    changedAt TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS serverState (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );",
            )
            .map_err(|err| describe("prepare the server tables in", err))?;
        Ok(Self {
            connection: Mutex::new(connection),
        })
    }

    fn connection(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.connection
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Every song's rating, keyed by its path relative to the music folder.
    pub fn ratings(&self) -> HashMap<String, i64> {
        let connection = self.connection();
        let Ok(mut statement) = connection.prepare("SELECT trackFileURL, rating FROM ratings") else {
            return HashMap::new();
        };
        let rows = statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?)));
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => HashMap::new(),
        }
    }

    /// Stores a rating from 1 to 5, or clears it for `None`.
    pub fn set_rating(&self, rel_path: &str, rating: Option<i64>) -> Result<(), rusqlite::Error> {
        let connection = self.connection();
        match rating {
            Some(rating) => connection
                .execute(
                    "INSERT INTO ratings (trackFileURL, rating) VALUES (?1, ?2)
                     ON CONFLICT(trackFileURL) DO UPDATE SET rating = excluded.rating",
                    params![rel_path, rating],
                )
                .map(|_| ()),
            None => connection
                .execute("DELETE FROM ratings WHERE trackFileURL = ?1", params![rel_path])
                .map(|_| ()),
        }
    }

    /// File size, audio fingerprint and MusicBrainz id of every track, by row id.
    pub fn track_extras(&self) -> HashMap<i64, TrackExtra> {
        let connection = self.connection();
        let Ok(mut statement) = connection
            .prepare("SELECT id, fileSize, audioFingerprint, musicBrainzID FROM tracks")
        else {
            return HashMap::new();
        };
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                TrackExtra {
                    size: row.get(1)?,
                    fingerprint: row.get(2)?,
                    musicbrainz_id: row.get(3)?,
                },
            ))
        });
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => HashMap::new(),
        }
    }

    /// Replaces the saved play queue.
    pub fn save_play_queue(&self, queue: &QueueRecord) -> Result<(), String> {
        let json = serde_json::to_string(queue)
            .map_err(|err| format!("Could not encode the play queue: {err}. This is a bug in flaccy-server; report it with this message."))?;
        self.connection()
            .execute(
                "INSERT INTO playQueue (id, json, changedAt) VALUES (1, ?1, ?2)
                 ON CONFLICT(id) DO UPDATE SET json = excluded.json, changedAt = excluded.changedAt",
                params![json, queue.changed_at],
            )
            .map(|_| ())
            .map_err(|err| format!("Could not save the play queue: {err}. Check that the data folder is writable and the disk is not full, then save it again."))
    }

    /// The saved play queue, `None` when no client has saved one.
    pub fn play_queue(&self) -> Option<QueueRecord> {
        let (json, changed_at): (String, String) = self
            .connection()
            .query_row("SELECT json, changedAt FROM playQueue WHERE id = 1", [], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })
            .optional()
            .ok()
            .flatten()?;
        let mut queue: QueueRecord = serde_json::from_str(&json).ok()?;
        queue.changed_at = changed_at;
        Some(queue)
    }

    /// Remembers `value` under `key` in the bookkeeping table.
    pub fn set_state(&self, key: &str, value: &str) {
        let _ = self.connection().execute(
            "INSERT INTO serverState (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        );
    }

    /// What `set_state` remembered under `key`.
    pub fn state(&self, key: &str) -> Option<String> {
        self.connection()
            .query_row("SELECT value FROM serverState WHERE key = ?1", params![key], |row| row.get(0))
            .optional()
            .ok()
            .flatten()
    }

    /// How many playlists exist.
    pub fn playlist_count(&self) -> i64 {
        self.connection()
            .query_row("SELECT COUNT(*) FROM playlists", [], |row| row.get(0))
            .unwrap_or(0)
    }
}
