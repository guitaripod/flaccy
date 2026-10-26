//! What the first connect merged, for the summary sheet of `docs/server/UX.md` section 4, and the Undo behind each line of it.
//!
//! Right after enrolling, the playlists and loves of this computer are queued for the server (see [`super::import`]). Their ids come from the song and the playlist name, so a playlist that exists on both sides has the same id on both. The first complete pull shows what the server already had; comparing it with the queue, before anything is sent, says which playlists were combined and which songs this computer now loves because another device loved them.

use super::base;
use super::error::{Result, SyncError};
use super::lookup::files_for_loves;
use super::meta;
use super::pending;
use super::songref::{refresh_index, Resolver};
use super::store::atomically;
use crate::db::Db;
use flaccy_server_core::model::SongRef;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashSet};

const PLAYLIST_CREATE: &str = "playlist.create";
const ENTRY_INSERT: &str = "entry.insert";
const LOVE_SET: &str = "love.set";

/// A song this computer put in a playlist before connecting.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LocalEntry {
    /// The entry id both sides derive.
    pub id: String,
    /// The song.
    pub song: SongRef,
}

/// A playlist that existed here and on the server.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MergedPlaylist {
    /// The playlist id on the server.
    pub id: String,
    /// The name the combined playlist has now, which is what the summary shows.
    pub name: String,
    /// The name this computer had given its own.
    pub local_name: String,
    /// What this computer had in it, in order.
    pub local: Vec<LocalEntry>,
    /// The ids of the entries the server already had.
    pub server: Vec<String>,
}

/// Everything the first connect combined.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct MergeReport {
    /// The playlists found on both sides.
    pub playlists: Vec<MergedPlaylist>,
    /// The song keys of songs the server had loved that this computer had not.
    pub loves: Vec<String>,
}

impl MergeReport {
    /// True when nothing merged, which is when no sheet is shown.
    pub fn is_empty(&self) -> bool {
        self.playlists.is_empty() && self.loves.is_empty()
    }
}

/// Remembers that the first pull has a merge to look at.
pub(crate) fn expect(conn: &Connection) -> Result<()> {
    meta::set(conn, meta::MERGE_PENDING, "1")
}

/// Looks at the base the first complete pull built, once. `None` when no merge was expected or nothing merged.
pub(crate) fn capture(conn: &Connection) -> Result<Option<MergeReport>> {
    if meta::get(conn, meta::MERGE_PENDING)?.is_none() {
        return Ok(None);
    }
    refresh_index(conn)?;
    let report = MergeReport {
        playlists: merged_playlists(conn)?,
        loves: merged_loves(conn)?,
    };
    meta::remove(conn, meta::MERGE_PENDING)?;
    Ok((!report.is_empty()).then_some(report))
}

fn merged_playlists(conn: &Connection) -> Result<Vec<MergedPlaylist>> {
    let rows = pending::all_rows(conn)?;
    let mut merged = Vec::new();
    for row in rows.iter().filter(|row| row.mutation.name == PLAYLIST_CREATE) {
        let args = &row.mutation.args;
        let (Some(id), Some(name)) = (args["id"].as_str(), args["name"].as_str()) else {
            continue;
        };
        let Some(doc) = base::doc(conn, id)? else {
            continue;
        };
        if !doc.playlist.alive {
            continue;
        }
        merged.push(MergedPlaylist {
            id: id.to_owned(),
            name: doc.playlist.name.clone(),
            local_name: name.to_owned(),
            local: local_entries(&rows, id),
            server: doc
                .entries
                .iter()
                .filter(|entry| entry.alive)
                .map(|entry| entry.id.clone())
                .collect(),
        });
    }
    Ok(merged)
}

fn local_entries(rows: &[pending::Row], playlist: &str) -> Vec<LocalEntry> {
    rows.iter()
        .filter(|row| row.mutation.name == ENTRY_INSERT)
        .filter(|row| row.mutation.args["playlist"].as_str() == Some(playlist))
        .filter_map(|row| {
            let args = &row.mutation.args;
            Some(LocalEntry {
                id: args["id"].as_str()?.to_owned(),
                song: serde_json::from_value(args["ref"].clone()).ok()?,
            })
        })
        .collect()
}

fn merged_loves(conn: &Connection) -> Result<Vec<String>> {
    let ours: HashSet<String> = pending::all_rows(conn)?
        .iter()
        .filter(|row| row.mutation.name == LOVE_SET)
        .filter_map(|row| row.mutation.args["songKey"].as_str().map(str::to_owned))
        .collect();
    let mut stmt = conn.prepare_cached(
        "SELECT b.id FROM sync_base b
         WHERE b.kind = ?1 AND b.deleted = 0
           AND EXISTS (SELECT 1 FROM sync_song_keys k WHERE k.songKey = b.id)
         ORDER BY b.id",
    )?;
    let rows = stmt.query_map(params![base::LOVE], |row| row.get::<_, String>(0))?;
    let mut keys = Vec::new();
    for key in rows {
        let key = key?;
        let loved = base::love(conn, &key)?.is_some_and(|love| love.loved);
        if loved && !ours.contains(&key) {
            keys.push(key);
        }
    }
    Ok(keys)
}

/// Keeps a combined playlist apart again: the entries only this computer added leave the server's playlist, and a playlist with the name and the songs this computer had becomes its own.
pub fn undo_playlist(db: &Db, merged: &MergedPlaylist) -> Result<()> {
    let conn = db.connection();
    atomically(conn, || {
        let shared: HashSet<&str> = merged.server.iter().map(String::as_str).collect();
        for entry in merged.local.iter().filter(|entry| !shared.contains(entry.id.as_str())) {
            for row_id in track_rows(conn, &entry.id)? {
                db.remove_playlist_track(row_id)?;
            }
        }
        let resolver = Resolver::new(conn);
        let mut paths = Vec::new();
        for entry in &merged.local {
            if let Some(path) = resolver.resolve(&entry.song)? {
                paths.push(path);
            }
        }
        let own = db.create_playlist(&merged.local_name)?;
        db.add_tracks_to_playlist(own, &paths)?;
        Ok(())
    })
}

fn track_rows(conn: &Connection, sync_id: &str) -> Result<Vec<i64>> {
    let mut stmt = conn.prepare_cached("SELECT id FROM playlistTracks WHERE syncId = ?1")?;
    let rows = stmt.query_map(params![sync_id], |row| row.get::<_, i64>(0))?;
    Ok(rows.collect::<std::result::Result<_, _>>()?)
}

/// Unloves the songs the merge loved here. Answers how many songs changed.
pub fn undo_loves(db: &Db, keys: &[String]) -> Result<usize> {
    let wanted: BTreeSet<String> = keys.iter().cloned().collect();
    let files = files_for_loves(db, &wanted)?;
    let mut changed = 0;
    for (file, _) in files.iter().filter(|(_, loved)| *loved) {
        db.set_loved(file, false, None).map_err(SyncError::Db)?;
        changed += 1;
    }
    Ok(changed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_report_shows_no_sheet() {
        assert!(MergeReport::default().is_empty());
        let loves = MergeReport {
            loves: vec!["k".into()],
            ..MergeReport::default()
        };
        assert!(!loves.is_empty());
    }
}
