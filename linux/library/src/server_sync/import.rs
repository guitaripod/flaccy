//! The first connect: what a database that already holds playlists, loves and
//! plays hands to a server it has just enrolled with. The identifiers are
//! derived by `flaccy_server_core::song::{playlist_id, entry_id}` (PROTOCOL.md
//! section 13), so two devices importing the same playlist converge on the same
//! entities.

use super::error::Result;
use super::ids::new_uuid_v7;
use super::listens::{append_all, requeue_all};
use super::meta;
use super::pending::{self, love_key, playlist_key, NewMutation};
use super::songref::ref_for_track;
use crate::db::unix_from_string;
use crate::listen_history::ListenKeyCache;
use flaccy_server_core::song::{entry_id, event_id_mig, normalize_playlist_name, playlist_id};
use flaccy_server_core::stamp::Stamp;
use rusqlite::{params, Connection};
use serde_json::json;
use std::collections::{HashMap, HashSet};

const IMPORT_FLOOR_MS: i64 = 1_577_836_800_000;

/// What the import queued.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ImportReport {
    /// Playlists given a sync id and queued.
    pub playlists: usize,
    /// Playlist entries queued.
    pub entries: usize,
    /// Loved songs queued.
    pub loves: usize,
    /// Plays that received a migrated event id.
    pub listens: usize,
}

/// Queues the local playlists, loves and plays once. A database that has already imported queues nothing.
pub(crate) fn run(conn: &Connection) -> Result<ImportReport> {
    if meta::get(conn, meta::IMPORTED)?.is_some() {
        return Ok(ImportReport::default());
    }
    let mut report = ImportReport::default();
    import_playlists(conn, &mut report)?;
    import_loves(conn, &mut report)?;
    report.listens = assign_event_ids(conn)?;
    append_all(conn, requeue_all(conn)?)?;
    meta::set(conn, meta::IMPORTED, "1")?;
    Ok(report)
}

fn import_playlists(conn: &Connection, report: &mut ImportReport) -> Result<()> {
    let playlists: Vec<(i64, String)> = {
        let mut stmt = conn.prepare(
            "SELECT id, name FROM playlists WHERE syncId IS NULL ORDER BY createdAt, id",
        )?;
        let rows = stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
        rows.collect::<std::result::Result<_, _>>()?
    };
    let mut taken = HashSet::new();
    for (local_id, name) in playlists {
        let id = if taken.insert(normalize_playlist_name(&name)) {
            playlist_id(&name, 0)
        } else {
            new_uuid_v7()
        };
        conn.execute(
            "UPDATE playlists SET syncId = ?1 WHERE id = ?2",
            params![id, local_id],
        )?;
        let touches = vec![playlist_key(&id)];
        pending::append(
            conn,
            NewMutation::new(
                "playlist.create",
                json!({ "id": id, "name": name }),
                touches.clone(),
            ),
        )?;
        report.playlists += 1;
        report.entries += import_entries(conn, local_id, &id, &touches)?;
    }
    Ok(())
}

fn import_entries(
    conn: &Connection,
    local_id: i64,
    playlist: &str,
    touches: &[String],
) -> Result<usize> {
    let rows: Vec<(i64, String)> = {
        let mut stmt = conn.prepare(
            "SELECT id, trackFileURL FROM playlistTracks WHERE playlistId = ?1 AND syncId IS NULL
             ORDER BY position, id",
        )?;
        let mapped = stmt.query_map(params![local_id], |row| Ok((row.get(0)?, row.get(1)?)))?;
        mapped.collect::<std::result::Result<_, _>>()?
    };
    let mut occurrences: HashMap<String, u32> = HashMap::new();
    let mut previous: Option<String> = None;
    let mut queued = 0;
    for (row_id, file_url) in rows {
        let Some(song) = ref_for_track(conn, &file_url)? else {
            continue;
        };
        let seen = occurrences.entry(song.song_key.clone()).or_default();
        let entry = entry_id(playlist, &song.song_key, *seen);
        *seen += 1;
        conn.execute(
            "UPDATE playlistTracks SET syncId = ?1 WHERE id = ?2",
            params![entry, row_id],
        )?;
        let place = match &previous {
            Some(before) => json!({ "kind": "after", "id": before }),
            None => json!({ "kind": "last" }),
        };
        let args = json!({ "id": entry, "playlist": playlist, "ref": song, "place": place });
        pending::append(
            conn,
            NewMutation::new("entry.insert", args, touches.to_vec()),
        )?;
        previous = Some(entry);
        queued += 1;
    }
    Ok(queued)
}

fn import_loves(conn: &Connection, report: &mut ImportReport) -> Result<()> {
    let loved: Vec<String> = {
        let mut stmt =
            conn.prepare("SELECT fileURL FROM tracks WHERE loved = 1 ORDER BY fileURL")?;
        let rows = stmt.query_map([], |row| row.get(0))?;
        rows.collect::<std::result::Result<_, _>>()?
    };
    let floor = Stamp::from_wall_ms(IMPORT_FLOOR_MS);
    let mut seen = HashSet::new();
    for file_url in loved {
        let Some(song) = ref_for_track(conn, &file_url)? else {
            continue;
        };
        if !seen.insert(song.song_key.clone()) {
            continue;
        }
        let key = song.song_key.clone();
        let args = json!({ "songKey": key, "ref": song, "loved": true });
        pending::append(
            conn,
            NewMutation::new("love.set", args, vec![love_key(&key)]).stamped(floor),
        )?;
        report.loves += 1;
    }
    Ok(())
}

/// Gives every stored play without an event id its migrated one. A repeat of the same second, title and artist is hidden locally, as the ledger will hide it on the server.
fn assign_event_ids(conn: &Connection) -> Result<usize> {
    let mut taken: HashSet<String> = {
        let mut stmt = conn.prepare("SELECT eventId FROM scrobbles WHERE eventId IS NOT NULL")?;
        let rows = stmt.query_map([], |row| row.get(0))?;
        rows.collect::<std::result::Result<_, _>>()?
    };
    let plays: Vec<(i64, String, String, String)> = {
        let mut stmt = conn.prepare(
            "SELECT id, timestamp, trackTitle, artist FROM scrobbles WHERE eventId IS NULL ORDER BY id",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })?;
        rows.collect::<std::result::Result<_, _>>()?
    };
    let mut cache = ListenKeyCache::default();
    let mut assign = conn.prepare("UPDATE scrobbles SET eventId = ?1 WHERE id = ?2")?;
    let mut hide = conn.prepare("UPDATE scrobbles SET suppressed = 1 WHERE id = ?1")?;
    let mut assigned = 0;
    for (id, timestamp, title, artist) in plays {
        let ts = unix_from_string(&timestamp);
        if ts < 0 {
            continue;
        }
        let title_key = cache.title(&title).to_owned();
        let event_id = event_id_mig(ts, &title_key, cache.artist(&artist));
        if taken.insert(event_id.clone()) {
            assign.execute(params![event_id, id])?;
            assigned += 1;
        } else {
            hide.execute(params![id])?;
        }
    }
    Ok(assigned)
}
