use super::error::Result;
use super::pending::{love_key, playlist_key, scalar_key};
use flaccy_server_core::model::{
    Entity, EntityKind, EntityValue, Entry, Love, Playlist, PlaylistDoc, Scalar,
};
use flaccy_server_core::wire::Change;
use rusqlite::{params, Connection, OptionalExtension};
use serde::de::DeserializeOwned;
use serde_json::Value;
use std::collections::HashMap;

pub(crate) const PLAYLIST: &str = "playlist";
pub(crate) const ENTRY: &str = "playlist_entry";
pub(crate) const LOVE: &str = "love";
pub(crate) const SCALAR: &str = "scalar";

fn kind_name(kind: EntityKind) -> String {
    serde_json::to_value(kind)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_default()
}

/// Stores a pulled change as the base of its entity. A value the core cannot decode is skipped. Answers the fold key of the entity it belongs to, when the app shows that kind.
pub(crate) fn put_change(conn: &Connection, change: &Change) -> Result<Option<String>> {
    let entity = Entity {
        kind: change.kind,
        id: change.id.clone(),
        value: change.value.clone(),
    };
    let Ok(decoded) = entity.decode() else {
        return Ok(None);
    };
    let parent = match &decoded {
        EntityValue::Entry(entry) => Some(entry.playlist.clone()),
        _ => None,
    };
    let fold_key = match &decoded {
        EntityValue::Playlist(playlist) => Some(playlist_key(&playlist.id)),
        EntityValue::Entry(entry) => Some(playlist_key(&entry.playlist)),
        EntityValue::Love(love) => Some(love_key(&love.song_key)),
        EntityValue::Scalar(scalar) => Some(scalar_key(&scalar.key)),
        EntityValue::Rating(_) | EntityValue::Session(_) => None,
    };
    let kind = kind_name(change.kind);
    conn.prepare_cached(
        "INSERT INTO sync_base (kind, id, parent, value_json, deleted) VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(kind, id) DO UPDATE SET
            parent = excluded.parent, value_json = excluded.value_json, deleted = excluded.deleted",
    )?
    .execute(params![
        kind,
        change.id,
        parent,
        serde_json::to_string(&change.value)?,
        change.deleted
    ])?;
    Ok(fold_key)
}

fn get<T: DeserializeOwned>(conn: &Connection, kind: &str, id: &str) -> Result<Option<T>> {
    let text: Option<String> = conn
        .prepare_cached("SELECT value_json FROM sync_base WHERE kind = ?1 AND id = ?2")?
        .query_row(params![kind, id], |row| row.get(0))
        .optional()?;
    Ok(match text {
        Some(text) => Some(serde_json::from_str(&text)?),
        None => None,
    })
}

/// The playlist and every entry of it, dead ones included, as the last pull left them.
pub(crate) fn doc(conn: &Connection, playlist_id: &str) -> Result<Option<PlaylistDoc>> {
    let Some(playlist) = get::<Playlist>(conn, PLAYLIST, playlist_id)? else {
        return Ok(None);
    };
    let mut stmt =
        conn.prepare_cached("SELECT value_json FROM sync_base WHERE kind = ?1 AND parent = ?2")?;
    let rows = stmt.query_map(params![ENTRY, playlist_id], |row| row.get::<_, String>(0))?;
    let mut entries = Vec::new();
    for text in rows {
        entries.push(serde_json::from_str::<Entry>(&text?)?);
    }
    Ok(Some(PlaylistDoc { playlist, entries }))
}

pub(crate) fn love(conn: &Connection, song_key: &str) -> Result<Option<Love>> {
    get(conn, LOVE, song_key)
}

pub(crate) fn scalar(conn: &Connection, key: &str) -> Result<Option<Scalar>> {
    get(conn, SCALAR, key)
}

/// The entities a reseed carries, in the order it must be sent: the user's own playlists, then the entries of each in playlist order and `(pos, id)` order, then every love, rating, scalar and session.
pub(crate) fn reseed_entities(conn: &Connection, user: &str) -> Result<Vec<Entity>> {
    let mut stmt =
        conn.prepare_cached("SELECT kind, id, value_json FROM sync_base ORDER BY kind, id")?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
        ))
    })?;
    let mut playlists = Vec::new();
    let mut entries: HashMap<String, Vec<Entity>> = HashMap::new();
    let mut others = Vec::new();
    for row in rows {
        let (kind, id, text) = row?;
        let value: Value = serde_json::from_str(&text)?;
        let kind: EntityKind = serde_json::from_value(Value::String(kind))?;
        match kind {
            EntityKind::Playlist if value["owner"].as_str() == Some(user) => {
                playlists.push(Entity { kind, id, value })
            }
            EntityKind::Playlist => {}
            EntityKind::PlaylistEntry => {
                let playlist = value["playlist"].as_str().unwrap_or_default().to_owned();
                entries
                    .entry(playlist)
                    .or_default()
                    .push(Entity { kind, id, value });
            }
            _ => others.push(Entity { kind, id, value }),
        }
    }
    let mut ordered = Vec::new();
    for playlist in &playlists {
        ordered.push(playlist.clone());
    }
    for playlist in playlists {
        let mut owned = entries.remove(&playlist.id).unwrap_or_default();
        owned.sort_by(|a, b| {
            let key = |entity: &Entity| {
                (
                    entity.value["pos"].as_str().unwrap_or_default().to_owned(),
                    entity.id.clone(),
                )
            };
            key(a).cmp(&key(b))
        });
        ordered.extend(owned);
    }
    ordered.extend(others);
    Ok(ordered)
}

pub(crate) fn clear(conn: &Connection) -> Result<()> {
    conn.execute("DELETE FROM sync_base", [])?;
    Ok(())
}
