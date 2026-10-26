use super::error::Result;
use crate::db::Db;
use rusqlite::params_from_iter;
use std::collections::BTreeSet;

const CHUNK: usize = 200;

/// The library files behind the song keys whose love a pull recomputed, with the loved flag they now carry, so the GUI can repaint the hearts it shows without scanning the library.
pub fn files_for_loves(db: &Db, keys: &BTreeSet<String>) -> Result<Vec<(String, bool)>> {
    let conn = db.connection();
    let keys: Vec<&String> = keys.iter().collect();
    let mut files = Vec::new();
    for chunk in keys.chunks(CHUNK) {
        let marks = vec!["?"; chunk.len()].join(",");
        let mut stmt = conn.prepare(&format!(
            "SELECT t.fileURL, t.loved FROM tracks t
             JOIN sync_song_keys k ON k.trackId = t.id WHERE k.songKey IN ({marks})"
        ))?;
        let rows = stmt.query_map(params_from_iter(chunk.iter()), |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?))
        })?;
        for row in rows {
            files.push(row?);
        }
    }
    Ok(files)
}
