//! The `m3u8` export: one playlist file per playlist, with paths a player can follow from the folder the files are in.

use std::collections::HashMap;
use std::io::Write;
use std::path::{Component, Path, PathBuf};

use flaccy_library::db::Db;
use flaccy_library::listen_history::{artist_listen_key, title_key};
use flaccy_server_core::song::song_key;
use rusqlite::Connection;
use serde_json::Value;

use crate::config::Config;
use crate::export::{open_state, safe_file_name, write_error, write_file, Exported, Subject};

const UNKNOWN_DURATION: i64 = -1;

/// Finds a song of the library from the reference a playlist entry holds.
#[derive(Clone, Debug, Default)]
pub struct Resolver {
    root: PathBuf,
    by_key: HashMap<String, String>,
    paths: HashMap<String, String>,
}

impl Resolver {
    /// A resolver that knows no songs, so every entry becomes a comment.
    pub fn empty(root: &Path) -> Self {
        Self { root: root.to_path_buf(), ..Self::default() }
    }

    /// Indexes `(artist, title, path relative to root)` triples; the first song with a key wins.
    pub fn from_tracks(root: &Path, tracks: impl IntoIterator<Item = (String, String, String)>) -> Self {
        let mut resolver = Self::empty(root);
        for (artist, title, rel_path) in tracks {
            let key = song_key(&artist_listen_key(&artist), &title_key(&title));
            resolver.by_key.entry(key).or_insert_with(|| rel_path.clone());
            resolver.paths.insert(rel_path.clone(), rel_path);
        }
        resolver
    }

    /// Indexes the songs `library.sqlite` holds, when it exists.
    pub fn from_library(config: &Config) -> Self {
        let path = config.database_path();
        if !path.is_file() {
            return Self::empty(&config.music_folder);
        }
        match Db::open(&path) {
            Ok(db) => {
                let mut rows = db.fetch_all_tracks();
                rows.sort_by_key(|row| row.id);
                Self::from_tracks(&config.music_folder, rows.into_iter().map(|row| (row.artist, row.title, row.rel_path)))
            }
            Err(_) => Self::empty(&config.music_folder),
        }
    }

    fn rel_path(&self, entry: &Value) -> Option<&str> {
        let named = entry["relPath"].as_str().and_then(|path| self.paths.get(path));
        let keyed = entry["songKey"].as_str().and_then(|key| self.by_key.get(key));
        named.or(keyed).map(String::as_str)
    }
}

/// `to` written relative to the folder `from`; both must be absolute.
pub fn relative_path(from: &Path, to: &Path) -> PathBuf {
    let from_parts: Vec<Component<'_>> = from.components().collect();
    let to_parts: Vec<Component<'_>> = to.components().collect();
    let shared = from_parts.iter().zip(&to_parts).take_while(|(a, b)| a == b).count();
    let mut relative = PathBuf::new();
    for _ in shared..from_parts.len() {
        relative.push("..");
    }
    for part in &to_parts[shared..] {
        relative.push(part.as_os_str());
    }
    relative
}

fn one_line(text: &str) -> String {
    text.chars().map(|c| if c.is_control() { ' ' } else { c }).collect::<String>().trim().to_owned()
}

fn display_name(entry: &Value) -> String {
    let artist = one_line(entry["artist"].as_str().unwrap_or_default());
    let title = one_line(entry["title"].as_str().unwrap_or_default());
    if artist.is_empty() {
        title
    } else {
        format!("{artist} - {title}")
    }
}

fn duration_seconds(entry: &Value) -> i64 {
    match entry["durationMs"].as_i64() {
        Some(millis) if millis > 0 => (millis + 500) / 1000,
        _ => UNKNOWN_DURATION,
    }
}

fn unique_file_name(taken: &mut Vec<String>, wanted: &str) -> String {
    let mut candidate = format!("{wanted}.m3u8");
    let mut number = 2;
    while taken.iter().any(|name| name.to_lowercase() == candidate.to_lowercase()) {
        candidate = format!("{wanted} ({number}).m3u8");
        number += 1;
    }
    taken.push(candidate.clone());
    candidate
}

fn write_entries(connection: &Connection, writer: &mut impl Write, playlist: &str, resolver: &Resolver, base: &Path) -> Result<usize, String> {
    let mut statement = connection
        .prepare("SELECT ref_json FROM playlist_entries WHERE playlist_id = ?1 AND alive = 1 ORDER BY pos, id")
        .map_err(|error| format!("The playlist entry query failed: {error}."))?;
    let mut rows = statement.query([playlist]).map_err(|error| error.to_string())?;
    let mut count = 0;
    while let Some(row) = rows.next().map_err(|error| error.to_string())? {
        let text: String = row.get(0).map_err(|error| error.to_string())?;
        let entry: Value = serde_json::from_str(&text).map_err(|error| format!("A playlist entry could not be read ({error}). Restore state.sqlite from a backup, or report this as a bug."))?;
        match resolver.rel_path(&entry) {
            Some(rel_path) => {
                let target = relative_path(base, &resolver.root.join(rel_path));
                writeln!(writer, "#EXTINF:{},{}\n{}", duration_seconds(&entry), display_name(&entry), target.to_string_lossy()).map_err(write_error)?;
            }
            None => writeln!(writer, "# {} (not in this library)", display_name(&entry)).map_err(write_error)?,
        }
        count += 1;
    }
    Ok(count)
}

/// Writes `<playlist name>.m3u8` into `out` for each live playlist the user owns.
pub fn export_playlists(state: &Path, subject: &Subject, out: &Path, resolver: &Resolver) -> Result<Exported, String> {
    let connection = open_state(state)?;
    let base = std::fs::canonicalize(out).unwrap_or_else(|_| out.to_path_buf());
    let resolver = Resolver { root: std::fs::canonicalize(&resolver.root).unwrap_or_else(|_| resolver.root.clone()), ..resolver.clone() };
    let mut playlists = connection
        .prepare("SELECT id, name FROM playlists WHERE owner = ?1 AND alive = 1 ORDER BY created_at, id")
        .map_err(|error| format!("The playlist query failed: {error}."))?;
    let listed = playlists
        .query_map([subject.id.as_str()], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
        .map_err(|error| error.to_string())?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| error.to_string())?;
    let mut taken = Vec::new();
    let mut exported = Exported { files: Vec::new(), items: 0 };
    for (id, name) in listed {
        let file_name = unique_file_name(&mut taken, &safe_file_name(&name));
        let (path, count) = write_file(out, &file_name, |writer| {
            writeln!(writer, "#EXTM3U\n#PLAYLIST:{}", one_line(&name)).map_err(write_error)?;
            write_entries(&connection, writer, &id, &resolver, &base)
        })?;
        exported.files.push(path);
        exported.items += count;
    }
    Ok(exported)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_is_written_relative_to_the_playlist_folder() {
        let from = Path::new("/home/me/exports");
        assert_eq!(relative_path(from, Path::new("/home/me/Music/A/b.flac")), PathBuf::from("../Music/A/b.flac"));
        assert_eq!(relative_path(Path::new("/home/me/Music"), Path::new("/home/me/Music/A/b.flac")), PathBuf::from("A/b.flac"));
        assert_eq!(relative_path(Path::new("/a/b/c"), Path::new("/x/y.flac")), PathBuf::from("../../../x/y.flac"));
    }

    #[test]
    fn colliding_playlist_names_get_numbers_ignoring_case() {
        let mut taken = Vec::new();
        assert_eq!(unique_file_name(&mut taken, "Mix"), "Mix.m3u8");
        assert_eq!(unique_file_name(&mut taken, "mix"), "mix (2).m3u8");
        assert_eq!(unique_file_name(&mut taken, "MIX"), "MIX (3).m3u8");
    }

    #[test]
    fn names_and_durations_read_from_the_reference() {
        let entry = serde_json::json!({ "artist": "Björk", "title": "Hyper\nballad", "durationMs": 321_600 });
        assert_eq!(display_name(&entry), "Björk - Hyper ballad");
        assert_eq!(duration_seconds(&entry), 322);
        assert_eq!(duration_seconds(&serde_json::json!({})), UNKNOWN_DURATION);
    }
}
