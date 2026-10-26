//! `flaccy-server export`: one user's data as files other programs read.
//!
//! Every format streams straight from SQLite to the file, so a million
//! listens never sit in memory, and each file is written beside its name and
//! renamed when complete. An export holds user data only: no tokens, no token
//! hashes and no Last.fm session keys, and no `lastfm/` preference.

use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};

use chrono::{SecondsFormat, Utc};
use clap::{Args, ValueEnum};
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::admin::say;
use crate::config::Config;
use crate::export_m3u::{self, Resolver};
use crate::security;

const WRITE_BUFFER_BYTES: usize = 256 * 1024;
const PARTIAL_SUFFIX: &str = ".partial";
const MAX_NAME_CHARS: usize = 100;
const UNSAFE_NAME_CHARS: &str = "/\\:*?\"<>|";

/// What to write.
#[derive(Clone, Copy, Debug, PartialEq, Eq, ValueEnum)]
pub enum Format {
    /// One document: playlists with their entries, loves, ratings, preferences and player sessions.
    Json,
    /// One `.m3u8` file per playlist.
    M3u8,
    /// Listens, one JSON object per line, in the shape ListenBrainz imports.
    Jsonl,
}

/// `flaccy-server export ...`
#[derive(Args, Debug)]
pub struct ExportArgs {
    /// The user whose data to export.
    #[arg(long)]
    pub user: String,
    /// json, m3u8 or jsonl.
    #[arg(long, value_enum)]
    pub format: Format,
    /// The folder to write into; it is created when missing.
    #[arg(long)]
    pub out: PathBuf,
}

/// The user an export is for.
#[derive(Clone, Debug)]
pub struct Subject {
    pub id: String,
    pub name: String,
}

/// What an export wrote.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Exported {
    pub files: Vec<PathBuf>,
    pub items: usize,
}

#[derive(Deserialize)]
struct Played {
    #[serde(default)]
    title: String,
    #[serde(default)]
    artist: String,
    #[serde(default)]
    album: String,
}

#[derive(Serialize)]
struct TrackMetadata<'a> {
    artist_name: &'a str,
    track_name: &'a str,
    #[serde(skip_serializing_if = "str::is_empty")]
    release_name: &'a str,
}

#[derive(Serialize)]
struct ListenLine<'a> {
    listened_at: i64,
    track_metadata: TrackMetadata<'a>,
}

/// A file name made of `raw` that no common file system refuses: path separators and the characters Windows bans become `_`.
pub fn safe_file_name(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        .map(|c| if c.is_control() || UNSAFE_NAME_CHARS.contains(c) { '_' } else { c })
        .take(MAX_NAME_CHARS)
        .collect();
    let trimmed = cleaned.trim_matches(|c: char| c.is_whitespace() || c == '.');
    if trimmed.is_empty() {
        "untitled".to_owned()
    } else {
        trimmed.to_owned()
    }
}

fn failed(what: &str, path: &Path, error: impl std::fmt::Display) -> String {
    format!("Could not {what} {}: {error}.", path.display())
}

pub(crate) fn open_state(path: &Path) -> Result<Connection, String> {
    if !path.is_file() {
        return Err(format!("There is no state.sqlite at {}, so there is nothing to export. Check `data_dir` in the configuration file.", path.display()));
    }
    Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)
        .map_err(|error| failed("open", path, error))
}

/// Writes `name` into `dir` through a `.partial` file that is renamed once `fill` has finished and the bytes are on disk.
pub(crate) fn write_file<T>(dir: &Path, name: &str, fill: impl FnOnce(&mut BufWriter<File>) -> Result<T, String>) -> Result<(PathBuf, T), String> {
    let path = dir.join(name);
    let partial = dir.join(format!("{name}{PARTIAL_SUFFIX}"));
    let outcome = (|| {
        let file = File::create(&partial).map_err(|error| failed("create", &partial, error))?;
        let mut writer = BufWriter::with_capacity(WRITE_BUFFER_BYTES, file);
        let value = fill(&mut writer)?;
        writer.flush().map_err(|error| failed("write", &partial, error))?;
        writer.get_ref().sync_all().map_err(|error| failed("flush", &partial, error))?;
        std::fs::rename(&partial, &path).map_err(|error| failed("move the finished export to", &path, error))?;
        Ok(value)
    })();
    if outcome.is_err() {
        let _ = std::fs::remove_file(&partial);
    }
    outcome.map(|value| (path, value))
}

pub(crate) fn write_error(error: std::io::Error) -> String {
    format!("Could not write the export: {error}. Free some disk space or choose another `--out` folder.")
}

pub(crate) fn to_line<T: Serialize>(writer: &mut impl Write, value: &T) -> Result<(), String> {
    serde_json::to_writer(&mut *writer, value).map_err(|error| write_error(error.into()))
}

fn parse_ref(text: &str, what: &str) -> Result<Value, String> {
    serde_json::from_str(text).map_err(|error| format!("A stored {what} could not be read ({error}). Restore state.sqlite from a backup, or leave that item out and report this as a bug."))
}

struct Section<'a, W: Write> {
    writer: &'a mut W,
    count: usize,
}

impl<'a, W: Write> Section<'a, W> {
    fn open(writer: &'a mut W, name: &str, first: bool) -> Result<Self, String> {
        let separator = if first { "" } else { "," };
        write!(writer, "{separator}\n\"{name}\": [").map_err(write_error)?;
        Ok(Self { writer, count: 0 })
    }

    fn item(&mut self, value: &Value) -> Result<(), String> {
        let separator = if self.count == 0 { "" } else { "," };
        write!(self.writer, "{separator}\n  ").map_err(write_error)?;
        to_line(self.writer, value)?;
        self.count += 1;
        Ok(())
    }

    fn close(self) -> Result<usize, String> {
        write!(self.writer, "\n]").map_err(write_error)?;
        Ok(self.count)
    }
}

fn song_section(connection: &Connection, writer: &mut impl Write, query: &SongQuery, user: &str, first: bool) -> Result<usize, String> {
    let name = query.name;
    let mut section = Section::open(writer, name, first)?;
    let mut statement = connection.prepare(query.sql).map_err(|error| format!("The {name} query failed: {error}."))?;
    let mut rows = statement.query([user]).map_err(|error| format!("The {name} query failed: {error}."))?;
    while let Some(row) = rows.next().map_err(|error| format!("Reading the {name} failed: {error}."))? {
        let key: String = row.get(0).map_err(|error| error.to_string())?;
        let text: String = row.get(1).map_err(|error| error.to_string())?;
        let number: i64 = row.get(2).map_err(|error| error.to_string())?;
        let mut item = serde_json::Map::new();
        item.insert("songKey".to_owned(), Value::from(key));
        item.insert("ref".to_owned(), parse_ref(&text, name)?);
        item.insert(query.number_name.to_owned(), Value::from(number));
        section.item(&Value::Object(item))?;
    }
    section.close()
}

struct SongQuery {
    name: &'static str,
    number_name: &'static str,
    sql: &'static str,
}

const LOVES: SongQuery = SongQuery {
    name: "loves",
    number_name: "stamp",
    sql: "SELECT song_key, ref_json, stamp FROM loves WHERE user_id = ?1 AND loved = 1 ORDER BY song_key",
};

const RATINGS: SongQuery = SongQuery {
    name: "ratings",
    number_name: "rating",
    sql: "SELECT song_key, ref_json, rating FROM ratings WHERE user_id = ?1 AND rating IS NOT NULL ORDER BY song_key",
};

fn playlist_section(connection: &Connection, writer: &mut impl Write, user: &str) -> Result<usize, String> {
    let mut section = Section::open(writer, "playlists", true)?;
    let mut playlists = connection
        .prepare("SELECT id, name, visibility, created_at FROM playlists WHERE owner = ?1 AND alive = 1 ORDER BY created_at, id")
        .map_err(|error| format!("The playlist query failed: {error}."))?;
    let mut entries = connection
        .prepare("SELECT id, ref_json FROM playlist_entries WHERE playlist_id = ?1 AND alive = 1 ORDER BY pos, id")
        .map_err(|error| format!("The playlist entry query failed: {error}."))?;
    let mut rows = playlists.query([user]).map_err(|error| error.to_string())?;
    while let Some(row) = rows.next().map_err(|error| error.to_string())? {
        let id: String = row.get(0).map_err(|error| error.to_string())?;
        let header = serde_json::json!({
            "id": id,
            "name": row.get::<_, String>(1).map_err(|error| error.to_string())?,
            "visibility": row.get::<_, String>(2).map_err(|error| error.to_string())?,
            "createdAt": row.get::<_, i64>(3).map_err(|error| error.to_string())?,
        });
        playlist_item(&mut section, &mut entries, &id, header)?;
    }
    section.close()
}

fn playlist_item<W: Write>(section: &mut Section<'_, W>, entries: &mut rusqlite::Statement<'_>, id: &str, header: Value) -> Result<(), String> {
    let separator = if section.count == 0 { "" } else { "," };
    let opening = serde_json::to_string(&header).map_err(|error| error.to_string())?;
    let body = opening.strip_suffix('}').unwrap_or(&opening);
    write!(section.writer, "{separator}\n  {body},\"entries\":[").map_err(write_error)?;
    let mut rows = entries.query([id]).map_err(|error| error.to_string())?;
    let mut first = true;
    while let Some(row) = rows.next().map_err(|error| error.to_string())? {
        let text: String = row.get(1).map_err(|error| error.to_string())?;
        let entry = serde_json::json!({ "id": row.get::<_, String>(0).map_err(|error| error.to_string())?, "ref": parse_ref(&text, "playlist entry")? });
        write!(section.writer, "{}", if first { "" } else { "," }).map_err(write_error)?;
        to_line(section.writer, &entry)?;
        first = false;
    }
    write!(section.writer, "]}}").map_err(write_error)?;
    section.count += 1;
    Ok(())
}

fn keyed_section(connection: &Connection, writer: &mut impl Write, sql: &str, name: &str, user: &str) -> Result<usize, String> {
    let mut section = Section::open(writer, name, false)?;
    let mut statement = connection.prepare(sql).map_err(|error| format!("The {name} query failed: {error}."))?;
    let mut rows = statement.query([user]).map_err(|error| error.to_string())?;
    while let Some(row) = rows.next().map_err(|error| error.to_string())? {
        let key: String = row.get(0).map_err(|error| error.to_string())?;
        let text: String = row.get(1).map_err(|error| error.to_string())?;
        section.item(&serde_json::json!({ "key": key, "value": parse_ref(&text, name)? }))?;
    }
    section.close()
}

/// Writes `export-<user>.json`: playlists with entries, loves, ratings, preferences and player sessions.
pub fn export_json(state: &Path, subject: &Subject, out: &Path) -> Result<Exported, String> {
    let connection = open_state(state)?;
    let name = format!("export-{}.json", safe_file_name(&subject.name));
    let (path, items) = write_file(out, &name, |writer| {
        let exported_at = Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true);
        write!(writer, "{{\n\"format\": \"flaccy-export\",\n\"version\": 1,\n\"exportedAt\": \"{exported_at}\",\n\"user\": ").map_err(write_error)?;
        to_line(writer, &subject.name)?;
        write!(writer, ",").map_err(write_error)?;
        let id = subject.id.as_str();
        let playlists = playlist_section(&connection, writer, id)?;
        let loves = song_section(&connection, writer, &LOVES, id, false)?;
        let ratings = song_section(&connection, writer, &RATINGS, id, false)?;
        let scalars = keyed_section(&connection, writer, "SELECT key, value_json FROM scalars WHERE user_id = ?1 AND deleted = 0 AND substr(key, 1, 7) <> 'lastfm/' ORDER BY key", "scalars", id)?;
        let sessions = keyed_section(&connection, writer, "SELECT device_id, session_json FROM sessions WHERE user_id = ?1 ORDER BY device_id", "sessions", id)?;
        write!(writer, "\n}}\n").map_err(write_error)?;
        Ok(playlists + loves + ratings + scalars + sessions)
    })?;
    Ok(Exported { files: vec![path], items })
}

/// Writes `listens-<user>.jsonl`: one ListenBrainz-style listen per line, oldest first, suppressed plays left out.
pub fn export_jsonl(state: &Path, subject: &Subject, out: &Path) -> Result<Exported, String> {
    let connection = open_state(state)?;
    let name = format!("listens-{}.jsonl", safe_file_name(&subject.name));
    let (path, items) = write_file(out, &name, |writer| {
        let mut statement = connection
            .prepare("SELECT ts, event_id, ref_json FROM listens WHERE user_id = ?1 AND suppressed = 0 ORDER BY ts, event_id")
            .map_err(|error| format!("The listens query failed: {error}."))?;
        let mut rows = statement.query([subject.id.as_str()]).map_err(|error| error.to_string())?;
        let mut count = 0;
        while let Some(row) = rows.next().map_err(|error| format!("Reading the listens failed: {error}."))? {
            let (ts, event_id, text): (i64, String, String) = (
                row.get(0).map_err(|error| error.to_string())?,
                row.get(1).map_err(|error| error.to_string())?,
                row.get(2).map_err(|error| error.to_string())?,
            );
            let played: Played = serde_json::from_str(&text).map_err(|error| format!("The listen {event_id} could not be read ({error}). Restore state.sqlite from a backup, or report this as a bug."))?;
            let line = ListenLine {
                listened_at: ts,
                track_metadata: TrackMetadata { artist_name: &played.artist, track_name: &played.title, release_name: &played.album },
            };
            to_line(writer, &line)?;
            writer.write_all(b"\n").map_err(write_error)?;
            count += 1;
        }
        Ok(count)
    })?;
    Ok(Exported { files: vec![path], items })
}

/// Writes the export `format` names into `out`, creating it when missing.
pub fn run(state: &Path, subject: &Subject, format: Format, out: &Path, resolver: &Resolver) -> Result<Exported, String> {
    std::fs::create_dir_all(out).map_err(|error| failed("create the export folder", out, error))?;
    match format {
        Format::Json => export_json(state, subject, out),
        Format::Jsonl => export_jsonl(state, subject, out),
        Format::M3u8 => export_m3u::export_playlists(state, subject, out, resolver),
    }
}

/// `export --user NAME --format F --out DIR`
pub async fn command(config: &Config, args: ExportArgs) -> Result<(), String> {
    let store = security::Store::open(&config.security_path()).await.map_err(|error| error.to_string())?;
    let found = store.find_user_by_name(&args.user).await.map_err(|error| error.to_string());
    let _ = store.close().await;
    let user = found?.ok_or_else(|| format!("There is no user called '{}'. List the users with `flaccy-server user list`.", args.user))?;
    let subject = Subject { id: user.id.to_string(), name: user.name };
    let resolver = if args.format == Format::M3u8 { Resolver::from_library(config) } else { Resolver::empty(&config.music_folder) };
    let state = config.state_path();
    let exported = tokio::task::spawn_blocking(move || run(&state, &subject, args.format, &args.out, &resolver))
        .await
        .map_err(|error| format!("The export thread stopped unexpectedly: {error}."))??;
    for file in &exported.files {
        say(&file.display().to_string());
    }
    say(&format!("Exported {} item(s) to {} file(s).", exported.items, exported.files.len()));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_names_lose_separators_and_reserved_characters() {
        assert_eq!(safe_file_name("AC/DC: Live?"), "AC_DC_ Live_");
        assert_eq!(safe_file_name("..\\..\\etc"), "_.._etc");
        assert_eq!(safe_file_name("  .hidden.  "), "hidden");
        assert_eq!(safe_file_name(""), "untitled");
        assert_eq!(safe_file_name("???"), "___");
        assert_eq!(safe_file_name("夜に駆ける – ヨルシカ"), "夜に駆ける – ヨルシカ");
        assert_eq!(safe_file_name(&"x".repeat(300)).chars().count(), MAX_NAME_CHARS);
    }
}
