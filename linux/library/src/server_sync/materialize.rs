use super::base;
use super::engine::Dirty;
use super::error::Result;
use super::meta;
use super::pending::{love_key, playlist_key, scalar_key, PendingIndex};
use super::songref::{refresh_index, Resolver};
use super::store::atomically;
use crate::db::{string_from_unix, Db};
use flaccy_server_core::apply::Caller;
use flaccy_server_core::model::{Entry, PlaylistDoc};
use flaccy_server_core::rebase::{fold_love, fold_playlist, fold_scalar};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

const LYRICS_PREFIX: &str = "lyr/";

/// A scalar whose visible value was recomputed; `None` means it is deleted.
pub(crate) struct ScalarChange {
    pub key: String,
    pub value: Option<Value>,
}

/// Recomputes the visible value of each dirty entity (its base with the live pending mutations folded over it) and writes it to the app tables.
pub(crate) fn refresh(
    conn: &Connection,
    dirty: &Dirty,
    caller: &Caller,
) -> Result<Vec<ScalarChange>> {
    if dirty.is_empty() {
        return Ok(Vec::new());
    }
    refresh_index(conn)?;
    let index = PendingIndex::load(conn)?;
    let resolver = Resolver::new(conn);
    for id in &dirty.playlists {
        let doc = base::doc(conn, id)?;
        let visible = fold_playlist(id, doc.as_ref(), caller, index.for_key(&playlist_key(id)));
        sync_playlist(conn, id, visible.as_ref(), &resolver)?;
    }
    for song_key in &dirty.loves {
        let love = base::love(conn, song_key)?;
        if let Some(love) = fold_love(
            song_key,
            love.as_ref(),
            caller,
            index.for_key(&love_key(song_key)),
        ) {
            set_loved(conn, song_key, love.loved)?;
        }
    }
    let mut changes = Vec::new();
    for key in &dirty.scalars {
        let stored = base::scalar(conn, key)?;
        let visible = fold_scalar(
            key,
            stored.as_ref(),
            caller,
            index.for_key(&scalar_key(key)),
        );
        let value = visible
            .filter(|scalar| !scalar.deleted)
            .map(|scalar| scalar.value);
        match (key.strip_prefix(LYRICS_PREFIX), &value) {
            (Some(song_key), Some(value)) => set_lyrics_offset(conn, song_key, value)?,
            (Some(_), None) => {}
            (None, _) => changes.push(ScalarChange {
                key: key.clone(),
                value,
            }),
        }
    }
    Ok(changes)
}

fn sync_playlist(
    conn: &Connection,
    id: &str,
    visible: Option<&PlaylistDoc>,
    resolver: &Resolver,
) -> Result<()> {
    let local: Option<i64> = conn
        .prepare_cached("SELECT id FROM playlists WHERE syncId = ?1")?
        .query_row(params![id], |row| row.get(0))
        .optional()?;
    let Some(doc) = visible.filter(|doc| doc.playlist.alive) else {
        if let Some(local) = local {
            conn.execute("DELETE FROM playlists WHERE id = ?1", params![local])?;
        }
        return clear_ghosts(conn, id);
    };
    let local = match local {
        Some(local) => {
            conn.prepare_cached("UPDATE playlists SET name = ?1 WHERE id = ?2 AND name <> ?1")?
                .execute(params![doc.playlist.name, local])?;
            local
        }
        None => {
            conn.prepare_cached(
                "INSERT INTO playlists (name, createdAt, syncId) VALUES (?1, ?2, ?3)",
            )?
            .execute(params![
                doc.playlist.name,
                string_from_unix(doc.playlist.created_at),
                id
            ])?;
            conn.last_insert_rowid()
        }
    };
    sync_entries(conn, local, id, doc, resolver)
}

struct LocalRow {
    row_id: i64,
    file_url: String,
    position: i64,
}

fn local_rows(conn: &Connection, playlist: i64) -> Result<HashMap<String, LocalRow>> {
    let mut stmt = conn.prepare_cached(
        "SELECT id, syncId, trackFileURL, position FROM playlistTracks
         WHERE playlistId = ?1 AND syncId IS NOT NULL",
    )?;
    let rows = stmt.query_map(params![playlist], |row| {
        Ok((
            row.get::<_, String>(1)?,
            LocalRow {
                row_id: row.get(0)?,
                file_url: row.get(2)?,
                position: row.get(3)?,
            },
        ))
    })?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

fn sync_entries(
    conn: &Connection,
    local: i64,
    id: &str,
    doc: &PlaylistDoc,
    resolver: &Resolver,
) -> Result<()> {
    let existing = local_rows(conn, local)?;
    let mut shown: Vec<(&Entry, String)> = Vec::new();
    let mut hidden: Vec<&Entry> = Vec::new();
    for entry in doc.visible() {
        match resolve_entry(resolver, &existing, entry)? {
            Some(file_url) => shown.push((entry, file_url)),
            None => hidden.push(entry),
        }
    }
    let mut insert = conn.prepare_cached(
        "INSERT INTO playlistTracks (playlistId, trackFileURL, position, syncId) VALUES (?1, ?2, ?3, ?4)",
    )?;
    let mut update = conn.prepare_cached(
        "UPDATE playlistTracks SET trackFileURL = ?1, position = ?2 WHERE id = ?3",
    )?;
    for (position, (entry, file_url)) in shown.iter().enumerate() {
        let position = position as i64;
        match existing.get(&entry.id) {
            Some(row) if row.file_url == *file_url && row.position == position => {}
            Some(row) => {
                update.execute(params![file_url, position, row.row_id])?;
            }
            None => {
                insert.execute(params![local, file_url, position, entry.id])?;
            }
        }
    }
    let kept: HashSet<&str> = shown.iter().map(|(entry, _)| entry.id.as_str()).collect();
    let mut delete = conn.prepare_cached("DELETE FROM playlistTracks WHERE id = ?1")?;
    for (entry_id, row) in &existing {
        if !kept.contains(entry_id.as_str()) {
            delete.execute(params![row.row_id])?;
        }
    }
    replace_ghosts(conn, id, &hidden)
}

fn resolve_entry(
    resolver: &Resolver,
    existing: &HashMap<String, LocalRow>,
    entry: &Entry,
) -> Result<Option<String>> {
    if let Some(row) = existing.get(&entry.id) {
        if resolver.path_has_song_key(&row.file_url, &entry.song.song_key)? {
            return Ok(Some(row.file_url.clone()));
        }
    }
    resolver.resolve(&entry.song)
}

fn clear_ghosts(conn: &Connection, playlist: &str) -> Result<()> {
    conn.prepare_cached("DELETE FROM sync_ghosts WHERE kind = 'entry' AND json_extract(value_json, '$.playlist') = ?1")?
        .execute(params![playlist])?;
    Ok(())
}

fn replace_ghosts(conn: &Connection, playlist: &str, hidden: &[&Entry]) -> Result<()> {
    clear_ghosts(conn, playlist)?;
    let mut insert = conn.prepare_cached(
        "INSERT INTO sync_ghosts (kind, id, value_json) VALUES ('entry', ?1, ?2)",
    )?;
    for entry in hidden {
        let value = json!({ "playlist": playlist, "ref": entry.song });
        insert.execute(params![entry.id, serde_json::to_string(&value)?])?;
    }
    Ok(())
}

fn set_loved(conn: &Connection, song_key: &str, loved: bool) -> Result<()> {
    conn.prepare_cached(
        "UPDATE tracks SET loved = ?1 WHERE loved <> ?1
         AND id IN (SELECT trackId FROM sync_song_keys WHERE songKey = ?2)",
    )?
    .execute(params![loved, song_key])?;
    Ok(())
}

fn set_lyrics_offset(conn: &Connection, song_key: &str, value: &Value) -> Result<()> {
    let Some(offset) = value.as_i64() else {
        return Ok(());
    };
    conn.prepare_cached(
        "UPDATE lyrics SET offsetMs = ?1 WHERE offsetMs <> ?1 AND EXISTS (
            SELECT 1 FROM tracks t JOIN sync_song_keys k ON k.trackId = t.id
            WHERE k.songKey = ?2 AND t.title = lyrics.trackTitle AND t.artist = lyrics.artist)",
    )?
    .execute(params![offset, song_key])?;
    Ok(())
}

/// The caller the fold runs as.
pub(crate) fn caller(conn: &Connection) -> Result<Option<Caller>> {
    Ok(meta::link(conn)?.map(|link| Caller::member(&link.user, &link.device)))
}

fn tracks_signature(conn: &Connection) -> Result<String> {
    let (count, newest, total, revisions): (i64, i64, i64, i64) = conn.query_row(
        "SELECT COUNT(*), COALESCE(MAX(id), 0), COALESCE(SUM(id), 0), COALESCE(SUM(revision), 0) FROM tracks",
        [],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
    )?;
    Ok(format!("{count}:{newest}:{total}:{revisions}"))
}

fn base_ids(conn: &Connection, kind: &str) -> Result<Vec<String>> {
    let mut stmt = conn.prepare_cached("SELECT id FROM sync_base WHERE kind = ?1")?;
    let rows = stmt.query_map(params![kind], |row| row.get::<_, String>(0))?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

/// Call after a library scan. Re-resolves every synced playlist against the library as it now is, so an entry hidden for want of its file appears when the file does, and reapplies synced lyrics offsets to lyrics fetched since. Does nothing while the library is unchanged.
pub fn resolve_ghosts(db: &Db) -> Result<Dirty> {
    let conn = db.connection();
    let Some(caller) = caller(conn)? else {
        return Ok(Dirty::default());
    };
    let signature = tracks_signature(conn)?;
    if meta::get(conn, meta::TRACKS_SIGNATURE)?.as_deref() == Some(signature.as_str()) {
        return Ok(Dirty::default());
    }
    atomically(conn, || {
        let mut dirty = Dirty::default();
        dirty.playlists.extend(base_ids(conn, base::PLAYLIST)?);
        dirty.playlists.extend(local_only_playlists(conn)?);
        dirty.scalars.extend(
            base_ids(conn, base::SCALAR)?
                .into_iter()
                .filter(|key| key.starts_with(LYRICS_PREFIX)),
        );
        refresh(conn, &dirty, &caller)?;
        meta::set(conn, meta::TRACKS_SIGNATURE, &signature)?;
        Ok(dirty)
    })
}

fn local_only_playlists(conn: &Connection) -> Result<Vec<String>> {
    let mut stmt = conn.prepare_cached("SELECT syncId FROM playlists WHERE syncId IS NOT NULL")?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}
