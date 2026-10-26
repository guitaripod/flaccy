//! What the OpenSubsonic calls read from the sync state: a user's loves, ratings
//! and play counts, the playlists they may see and the sessions their devices saved.

use std::collections::HashMap;

use flaccy_server_core::model::{PlaylistDoc, SessionDoc, Visibility};
use flaccy_server_core::stamp::Stamp;
use rusqlite::{Connection, OptionalExtension};

use super::rows::{load_entries, load_playlist, UserRow};
use super::{Store, SyncError};
use crate::security::UserId;

/// How often a user played a song and when they last did, counting every play the ledger kept.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PlayStat {
    /// The plays that are not suppressed.
    pub count: i64,
    /// The start of the latest one, in Unix seconds.
    pub last: i64,
}

/// A user's per-song state, keyed by song key.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct UserState {
    /// Loved songs with the wall time of the write, in Unix milliseconds.
    pub loved: HashMap<String, i64>,
    /// Rated songs, one to five stars.
    pub ratings: HashMap<String, u8>,
    /// Plays per song.
    pub plays: HashMap<String, PlayStat>,
}

fn loved_songs(connection: &Connection, user: &str) -> Result<HashMap<String, i64>, SyncError> {
    let mut statement = connection.prepare_cached("SELECT song_key, stamp FROM loves WHERE user_id = ?1 AND loved = 1")?;
    let rows = statement
        .query_map([user], |row| Ok((row.get::<_, String>(0)?, Stamp(row.get(1)?).wall_ms())))?
        .collect::<Result<HashMap<_, _>, _>>()?;
    Ok(rows)
}

fn rated_songs(connection: &Connection, user: &str) -> Result<HashMap<String, u8>, SyncError> {
    let mut statement =
        connection.prepare_cached("SELECT song_key, rating FROM ratings WHERE user_id = ?1 AND rating IS NOT NULL")?;
    let rows = statement
        .query_map([user], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?
        .filter_map(|row| match row {
            Ok((key, stars)) => u8::try_from(stars).ok().map(|stars| Ok((key, stars))),
            Err(error) => Some(Err(error)),
        })
        .collect::<Result<HashMap<_, _>, _>>()?;
    Ok(rows)
}

fn played_songs(connection: &Connection, user: &str) -> Result<HashMap<String, PlayStat>, SyncError> {
    let mut statement = connection.prepare_cached(
        "SELECT song_key, COUNT(*), MAX(ts) FROM listens WHERE user_id = ?1 AND suppressed = 0 GROUP BY song_key",
    )?;
    let rows = statement
        .query_map([user], |row| {
            Ok((
                row.get::<_, String>(0)?,
                PlayStat {
                    count: row.get(1)?,
                    last: row.get(2)?,
                },
            ))
        })?
        .collect::<Result<HashMap<_, _>, _>>()?;
    Ok(rows)
}

fn may_read(doc: &PlaylistDoc, user: &str) -> bool {
    doc.playlist.alive && (doc.playlist.owner == user || doc.playlist.visibility == Visibility::Household)
}

fn visible_ids(connection: &Connection, user: &str) -> Result<Vec<String>, SyncError> {
    let mut statement = connection.prepare_cached(
        "SELECT id FROM playlists WHERE alive = 1 AND (owner = ?1 OR visibility = 'household') ORDER BY created_at, id",
    )?;
    let ids = statement.query_map([user], |row| row.get(0))?.collect::<Result<Vec<String>, _>>()?;
    Ok(ids)
}

fn load_visible(connection: &Connection, user: &str, id: &str) -> Result<Option<PlaylistDoc>, SyncError> {
    let Some(playlist) = load_playlist(connection, id)? else {
        return Ok(None);
    };
    let entries = load_entries(connection, id)?;
    let doc = PlaylistDoc { playlist, entries };
    Ok(may_read(&doc, user).then_some(doc))
}

impl Store {
    /// The user's loves, ratings and play counts.
    pub async fn user_state(&self, user: &UserId) -> Result<UserState, SyncError> {
        let user = user.to_string();
        self.read(move |connection| {
            let snapshot = connection.unchecked_transaction()?;
            Ok::<_, SyncError>(UserState {
                loved: loved_songs(&snapshot, &user)?,
                ratings: rated_songs(&snapshot, &user)?,
                plays: played_songs(&snapshot, &user)?,
            })
        })
        .await
    }

    /// The living playlists `user` may see, their own and the household's, oldest first, each with its entries.
    pub async fn playlists_for(&self, user: &UserId) -> Result<Vec<PlaylistDoc>, SyncError> {
        let user = user.to_string();
        self.read(move |connection| {
            let snapshot = connection.unchecked_transaction()?;
            let mut docs = Vec::new();
            for id in visible_ids(&snapshot, &user)? {
                docs.extend(load_visible(&snapshot, &user, &id)?);
            }
            Ok::<_, SyncError>(docs)
        })
        .await
    }

    /// The living playlist `id` when `user` may see it.
    pub async fn playlist_for(&self, user: &UserId, id: &str) -> Result<Option<PlaylistDoc>, SyncError> {
        let user = user.to_string();
        let id = id.to_owned();
        self.read(move |connection| load_visible(connection, &user, &id)).await
    }

    /// The sessions the user's devices saved, newest first.
    pub async fn sessions_of(&self, user: &UserId) -> Result<Vec<SessionDoc>, SyncError> {
        let user = user.to_string();
        self.read(move |connection| {
            let mut statement = connection.prepare_cached(
                "SELECT device_id FROM sessions WHERE user_id = ?1 ORDER BY stamp DESC, device_id",
            )?;
            let devices = statement.query_map([&user], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?;
            let mut sessions = Vec::with_capacity(devices.len());
            for device in devices {
                sessions.extend(<SessionDoc as UserRow>::load(connection, &user, &device)?);
            }
            Ok::<_, SyncError>(sessions)
        })
        .await
    }

    /// The value stored under `key` in `server_meta`.
    pub async fn meta_value(&self, key: &str) -> Result<Option<String>, SyncError> {
        let key = key.to_owned();
        self.read(move |connection| {
            Ok::<_, SyncError>(
                connection
                    .prepare_cached("SELECT value FROM server_meta WHERE key = ?1")?
                    .query_row([&key], |row| row.get(0))
                    .optional()?,
            )
        })
        .await
    }

    /// Stores `value` under `key` in `server_meta`.
    pub async fn set_meta_value(&self, key: &str, value: &str) -> Result<(), SyncError> {
        let key = key.to_owned();
        let value = value.to_owned();
        self.write(move |connection| {
            connection
                .prepare_cached(
                    "INSERT INTO server_meta(key, value) VALUES (?1, ?2)
                     ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                )?
                .execute((&key, &value))?;
            Ok::<_, SyncError>(())
        })
        .await
    }
}
