//! What the first connect merged, for the summary sheet of `docs/server/UX.md` section 4.
//!
//! Right after enrolling, the playlists and loves of this computer are queued for the server (see [`super::import`]). Their ids come from the song and the playlist name, so a playlist that exists on both sides has the same id on both. The first complete pull shows what the server already had; comparing it with the queue, before anything is sent, says which playlists were combined and which songs this computer now loves because another device loved them.

use super::base;
use super::error::Result;
use super::meta;
use super::pending;
use super::songref::refresh_index;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

const PLAYLIST_CREATE: &str = "playlist.create";
const LOVE_SET: &str = "love.set";

/// A playlist that existed here and on the server.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MergedPlaylist {
    /// The playlist id on the server.
    pub id: String,
    /// The name the combined playlist has now, which is what the summary shows.
    pub name: String,
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
    let mut merged = Vec::new();
    for row in pending::all_rows(conn)?
        .iter()
        .filter(|row| row.mutation.name == PLAYLIST_CREATE)
    {
        let Some(id) = row.mutation.args["id"].as_str() else {
            continue;
        };
        let Some(doc) = base::doc(conn, id)? else {
            continue;
        };
        if doc.playlist.alive {
            merged.push(MergedPlaylist {
                id: id.to_owned(),
                name: doc.playlist.name.clone(),
            });
        }
    }
    Ok(merged)
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
