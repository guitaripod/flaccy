//! Reading and writing the entity tables, one prepared statement per shape.

use flaccy_server_core::apply::Mergeable;
use flaccy_server_core::model::{
    EntityKind, EntityValue, Entry, EntryStamps, Love, Playlist, PlaylistStamps, Rating, Scalar, SessionDoc,
    SongRef, Visibility,
};
use flaccy_server_core::stamp::Stamp;
use rusqlite::types::Type;
use rusqlite::{Connection, OptionalExtension, Row};
use serde::de::DeserializeOwned;
use serde_json::Value;

use super::SyncError;

fn conversion_failure(column: usize, cause: impl std::error::Error + Send + Sync + 'static) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(column, Type::Text, Box::new(cause))
}

#[derive(Debug)]
struct UnknownWord(String);

impl std::fmt::Display for UnknownWord {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "unknown stored word '{}'", self.0)
    }
}

impl std::error::Error for UnknownWord {}

fn json_column<T: DeserializeOwned>(row: &Row<'_>, column: usize) -> rusqlite::Result<T> {
    let text: String = row.get(column)?;
    serde_json::from_str(&text).map_err(|error| conversion_failure(column, error))
}

/// The word a visibility is stored as.
pub(super) fn visibility_text(visibility: Visibility) -> &'static str {
    match visibility {
        Visibility::Private => "private",
        Visibility::Household => "household",
    }
}

fn visibility_column(row: &Row<'_>, column: usize) -> rusqlite::Result<Visibility> {
    let word: String = row.get(column)?;
    match word.as_str() {
        "private" => Ok(Visibility::Private),
        "household" => Ok(Visibility::Household),
        _ => Err(conversion_failure(column, UnknownWord(word))),
    }
}

fn to_json<T: serde::Serialize>(value: &T) -> Result<String, SyncError> {
    serde_json::to_string(value).map_err(|error| SyncError::Corrupt(format!("a value would not serialize: {error}")))
}

const PLAYLIST_COLUMNS: &str =
    "id, owner, name, cover_blob, visibility, alive, created_at, st_name, st_cover, st_visibility, st_alive";

fn playlist_from_row(row: &Row<'_>) -> rusqlite::Result<Playlist> {
    Ok(Playlist {
        id: row.get(0)?,
        owner: row.get(1)?,
        name: row.get(2)?,
        cover_blob: row.get(3)?,
        visibility: visibility_column(row, 4)?,
        alive: row.get(5)?,
        created_at: row.get(6)?,
        stamps: PlaylistStamps {
            name: Stamp(row.get(7)?),
            cover: Stamp(row.get(8)?),
            visibility: Stamp(row.get(9)?),
            alive: Stamp(row.get(10)?),
        },
    })
}

/// The playlist with this id, dead or alive.
pub(super) fn load_playlist(connection: &Connection, id: &str) -> Result<Option<Playlist>, SyncError> {
    Ok(connection
        .prepare_cached(&format!("SELECT {PLAYLIST_COLUMNS} FROM playlists WHERE id = ?1"))?
        .query_row([id], playlist_from_row)
        .optional()?)
}

/// Inserts or replaces a playlist row.
pub(super) fn save_playlist(connection: &Connection, playlist: &Playlist) -> Result<(), SyncError> {
    connection
        .prepare_cached(&format!(
            "INSERT INTO playlists({PLAYLIST_COLUMNS}) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
             ON CONFLICT(id) DO UPDATE SET owner = excluded.owner, name = excluded.name, cover_blob = excluded.cover_blob,
                 visibility = excluded.visibility, alive = excluded.alive, created_at = excluded.created_at,
                 st_name = excluded.st_name, st_cover = excluded.st_cover, st_visibility = excluded.st_visibility,
                 st_alive = excluded.st_alive"
        ))?
        .execute((
            &playlist.id,
            &playlist.owner,
            &playlist.name,
            &playlist.cover_blob,
            visibility_text(playlist.visibility),
            playlist.alive,
            playlist.created_at,
            playlist.stamps.name.0,
            playlist.stamps.cover.0,
            playlist.stamps.visibility.0,
            playlist.stamps.alive.0,
        ))?;
    Ok(())
}

const ENTRY_COLUMNS: &str = "id, playlist_id, ref_json, pos, alive, st_ref, st_pos, st_alive";

fn entry_from_row(row: &Row<'_>) -> rusqlite::Result<Entry> {
    Ok(Entry {
        id: row.get(0)?,
        playlist: row.get(1)?,
        song: json_column::<SongRef>(row, 2)?,
        pos: row.get(3)?,
        alive: row.get(4)?,
        stamps: EntryStamps {
            song: Stamp(row.get(5)?),
            pos: Stamp(row.get(6)?),
            alive: Stamp(row.get(7)?),
        },
    })
}

/// The entry with this id, in whichever playlist holds it.
pub(super) fn load_entry(connection: &Connection, id: &str) -> Result<Option<Entry>, SyncError> {
    Ok(connection
        .prepare_cached(&format!("SELECT {ENTRY_COLUMNS} FROM playlist_entries WHERE id = ?1"))?
        .query_row([id], entry_from_row)
        .optional()?)
}

/// Every entry of a playlist, dead ones included, in no particular order.
pub(super) fn load_entries(connection: &Connection, playlist_id: &str) -> Result<Vec<Entry>, SyncError> {
    let mut statement =
        connection.prepare_cached(&format!("SELECT {ENTRY_COLUMNS} FROM playlist_entries WHERE playlist_id = ?1"))?;
    let entries = statement.query_map([playlist_id], entry_from_row)?.collect::<Result<Vec<_>, _>>()?;
    Ok(entries)
}

/// The playlist an entry id belongs to, if the id is taken.
pub(super) fn entry_playlist(connection: &Connection, entry_id: &str) -> Result<Option<String>, SyncError> {
    Ok(connection
        .prepare_cached("SELECT playlist_id FROM playlist_entries WHERE id = ?1")?
        .query_row([entry_id], |row| row.get(0))
        .optional()?)
}

/// Inserts or replaces an entry row.
pub(super) fn save_entry(connection: &Connection, entry: &Entry) -> Result<(), SyncError> {
    connection
        .prepare_cached(&format!(
            "INSERT INTO playlist_entries({ENTRY_COLUMNS}) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(id) DO UPDATE SET ref_json = excluded.ref_json, pos = excluded.pos, alive = excluded.alive,
                 st_ref = excluded.st_ref, st_pos = excluded.st_pos, st_alive = excluded.st_alive"
        ))?
        .execute((
            &entry.id,
            &entry.playlist,
            to_json(&entry.song)?,
            &entry.pos,
            entry.alive,
            entry.stamps.song.0,
            entry.stamps.pos.0,
            entry.stamps.alive.0,
        ))?;
    Ok(())
}

/// An entity that lives in a per-user table, keyed by user and its own key.
pub(super) trait UserRow: Mergeable + Sized {
    /// The key within the user's rows.
    fn key(&self) -> &str;

    /// The user's row with this key.
    fn load(connection: &Connection, user: &str, key: &str) -> Result<Option<Self>, SyncError>;

    /// Inserts or replaces the user's row.
    fn save(&self, connection: &Connection, user: &str) -> Result<(), SyncError>;

    /// The row as the entity union carries it.
    fn wrap(self) -> EntityValue;
}

impl UserRow for Love {
    fn key(&self) -> &str {
        &self.song_key
    }

    fn load(connection: &Connection, user: &str, key: &str) -> Result<Option<Self>, SyncError> {
        Ok(connection
            .prepare_cached("SELECT ref_json, loved, stamp FROM loves WHERE user_id = ?1 AND song_key = ?2")?
            .query_row((user, key), |row| {
                Ok(Love {
                    song_key: key.to_owned(),
                    song: json_column(row, 0)?,
                    loved: row.get(1)?,
                    stamp: Stamp(row.get(2)?),
                })
            })
            .optional()?)
    }

    fn save(&self, connection: &Connection, user: &str) -> Result<(), SyncError> {
        connection
            .prepare_cached(
                "INSERT INTO loves(user_id, song_key, ref_json, loved, stamp) VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(user_id, song_key) DO UPDATE SET ref_json = excluded.ref_json, loved = excluded.loved,
                     stamp = excluded.stamp",
            )?
            .execute((user, &self.song_key, to_json(&self.song)?, self.loved, self.stamp.0))?;
        Ok(())
    }

    fn wrap(self) -> EntityValue {
        EntityValue::Love(self)
    }
}

impl UserRow for Rating {
    fn key(&self) -> &str {
        &self.song_key
    }

    fn load(connection: &Connection, user: &str, key: &str) -> Result<Option<Self>, SyncError> {
        Ok(connection
            .prepare_cached("SELECT ref_json, rating, stamp FROM ratings WHERE user_id = ?1 AND song_key = ?2")?
            .query_row((user, key), |row| {
                let stars: Option<i64> = row.get(1)?;
                Ok(Rating {
                    song_key: key.to_owned(),
                    song: json_column(row, 0)?,
                    rating: stars.and_then(|stars| u8::try_from(stars).ok()),
                    stamp: Stamp(row.get(2)?),
                })
            })
            .optional()?)
    }

    fn save(&self, connection: &Connection, user: &str) -> Result<(), SyncError> {
        connection
            .prepare_cached(
                "INSERT INTO ratings(user_id, song_key, ref_json, rating, stamp) VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(user_id, song_key) DO UPDATE SET ref_json = excluded.ref_json, rating = excluded.rating,
                     stamp = excluded.stamp",
            )?
            .execute((user, &self.song_key, to_json(&self.song)?, self.rating.map(i64::from), self.stamp.0))?;
        Ok(())
    }

    fn wrap(self) -> EntityValue {
        EntityValue::Rating(self)
    }
}

impl UserRow for Scalar {
    fn key(&self) -> &str {
        &self.key
    }

    fn load(connection: &Connection, user: &str, key: &str) -> Result<Option<Self>, SyncError> {
        Ok(connection
            .prepare_cached("SELECT value_json, deleted, stamp FROM scalars WHERE user_id = ?1 AND key = ?2")?
            .query_row((user, key), |row| {
                Ok(Scalar {
                    key: key.to_owned(),
                    value: json_column::<Value>(row, 0)?,
                    deleted: row.get(1)?,
                    stamp: Stamp(row.get(2)?),
                })
            })
            .optional()?)
    }

    fn save(&self, connection: &Connection, user: &str) -> Result<(), SyncError> {
        connection
            .prepare_cached(
                "INSERT INTO scalars(user_id, key, value_json, deleted, stamp) VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(user_id, key) DO UPDATE SET value_json = excluded.value_json, deleted = excluded.deleted,
                     stamp = excluded.stamp",
            )?
            .execute((user, &self.key, to_json(&self.value)?, self.deleted, self.stamp.0))?;
        Ok(())
    }

    fn wrap(self) -> EntityValue {
        EntityValue::Scalar(self)
    }
}

impl UserRow for SessionDoc {
    fn key(&self) -> &str {
        &self.device
    }

    fn load(connection: &Connection, user: &str, key: &str) -> Result<Option<Self>, SyncError> {
        Ok(connection
            .prepare_cached("SELECT session_json, stamp FROM sessions WHERE user_id = ?1 AND device_id = ?2")?
            .query_row((user, key), |row| {
                Ok(SessionDoc {
                    device: key.to_owned(),
                    session: json_column::<Value>(row, 0)?,
                    stamp: Stamp(row.get(1)?),
                })
            })
            .optional()?)
    }

    fn save(&self, connection: &Connection, user: &str) -> Result<(), SyncError> {
        connection
            .prepare_cached(
                "INSERT INTO sessions(user_id, device_id, session_json, stamp) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(user_id, device_id) DO UPDATE SET session_json = excluded.session_json, stamp = excluded.stamp",
            )?
            .execute((user, &self.device, to_json(&self.session)?, self.stamp.0))?;
        Ok(())
    }

    fn wrap(self) -> EntityValue {
        EntityValue::Session(self)
    }
}

/// The user's own entity of a per-user kind, `None` for other kinds or a missing row.
pub(super) fn load_user_entity(
    connection: &Connection,
    user: &str,
    kind: EntityKind,
    key: &str,
) -> Result<Option<EntityValue>, SyncError> {
    Ok(match kind {
        EntityKind::Love => Love::load(connection, user, key)?.map(UserRow::wrap),
        EntityKind::Rating => Rating::load(connection, user, key)?.map(UserRow::wrap),
        EntityKind::Scalar => Scalar::load(connection, user, key)?.map(UserRow::wrap),
        EntityKind::Session => SessionDoc::load(connection, user, key)?.map(UserRow::wrap),
        EntityKind::Playlist | EntityKind::PlaylistEntry | EntityKind::Listen => None,
    })
}
