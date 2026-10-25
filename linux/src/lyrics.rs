use crate::db::{Db, LyricsContent, LyricsRow};
use crate::library::Track;
use flaccy_shared::lyrics::{
    best_candidate, clean_title, lead_artist, parse_lrc, parse_lyricsfile, Candidate, Document,
    LyricsFailure, Wanted,
};
use std::path::Path;
use std::time::Duration;

/// The generation of the lyrics pipeline that stores rows. Rows saved before
/// line ends and word timing existed hold content that a second look at the
/// server can improve, so they are asked for once more.
const REVISION: i64 = 2;

/// A lyrics answer can be a minute of the server's patience; past this the
/// request is given up on and the panel offers Try Again.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
/// The pause before the one retry of a request the server turned away, when it
/// does not say how long to wait, and the bounds on what it may ask for.
const DEFAULT_RETRY_WAIT: f64 = 0.8;
const SHORTEST_RETRY_WAIT: f64 = 0.3;
const LONGEST_RETRY_WAIT: f64 = 3.0;

/// How long a remembered miss stands before lrclib is asked again — the corpus
/// is community-contributed and grows.
const MISS_TTL_DAYS: f64 = 30.0;

/// One track's lyrics together with the listener's own timing correction.
#[derive(Clone, Default)]
pub struct Lyrics {
    pub document: Document,
    pub offset_ms: i64,
}

impl Lyrics {
    /// The correction in seconds, positive meaning every line comes later.
    pub fn offset_seconds(&self) -> f64 {
        self.offset_ms as f64 / 1000.0
    }

    /// The moment of the song to look up for a playback position: the position
    /// less the correction.
    pub fn song_time(&self, position: f64) -> f64 {
        position - self.offset_seconds()
    }

    /// The sung line at a playback position, for surfaces that show one line.
    pub fn text_at(&self, position: f64) -> Option<&str> {
        self.document.text_at(self.song_time(position))
    }
}

/// Distinguishes "lrclib has nothing for this track" from "we couldn't ask",
/// and says why we couldn't. A miss is cached (and expires); a failure is not,
/// so a flaky network never leaves a permanently blank panel.
#[derive(Clone)]
pub enum LyricsResult {
    Found(Lyrics),
    Missing,
    Failed(LyricsFailure),
}

fn user_agent() -> String {
    format!(
        "flaccy/{} (https://github.com/guitaripod/flaccy)",
        env!("CARGO_PKG_VERSION")
    )
}

/// Builds the document a stored or fetched answer describes. A Lyricsfile wins
/// when it reads cleanly and holds synchronized lines; otherwise the LRC text
/// does.
fn document_from(
    synced: Option<&str>,
    plain: Option<&str>,
    lyricsfile: Option<&str>,
    instrumental: bool,
) -> Document {
    if instrumental {
        return Document {
            instrumental: true,
            ..Document::default()
        };
    }
    let from_file = lyricsfile
        .and_then(parse_lyricsfile)
        .filter(Document::has_synced);
    let mut document = match (from_file, synced) {
        (Some(document), _) => document,
        (None, Some(synced)) => parse_lrc(synced),
        (None, None) => Document::default(),
    };
    if document.plain.is_none() {
        document.plain = plain
            .filter(|text| !text.trim().is_empty())
            .map(str::to_string);
    }
    document
}

fn lyrics_from_row(row: &LyricsRow) -> Lyrics {
    Lyrics {
        document: document_from(
            row.synced.as_deref(),
            row.plain.as_deref(),
            row.lyricsfile.as_deref(),
            row.instrumental,
        ),
        offset_ms: row.offset_ms,
    }
}

fn has_content(row: &LyricsRow) -> bool {
    row.instrumental
        || is_filled(row.synced.as_deref())
        || is_filled(row.plain.as_deref())
        || is_filled(row.lyricsfile.as_deref())
}

fn is_filled(text: Option<&str>) -> bool {
    text.is_some_and(|text| !text.trim().is_empty())
}

/// A row is served as it stands unless it is a miss old enough to ask again
/// about, or holds content from before the current pipeline revision.
fn is_current(row: &LyricsRow) -> bool {
    if has_content(row) {
        row.revision >= REVISION
    } else {
        row.age_days <= MISS_TTL_DAYS
    }
}

fn found_or_missing(lyrics: Lyrics) -> LyricsResult {
    if lyrics.document.is_empty() {
        LyricsResult::Missing
    } else {
        LyricsResult::Found(lyrics)
    }
}

/// Resolution order: the local database cache, then lyrics the user keeps
/// alongside the audio (`.lrc` sidecar or an embedded tag), then lrclib. A
/// cached answer from an older pipeline revision is shown if the server cannot
/// improve on it, and a cached miss never hides a file the listener has added
/// since. An unreadable cache costs only the memory, never the lookup.
pub fn fetch_blocking(db_path: &Path, music_root: &Path, track: &Track) -> LyricsResult {
    let db = Db::open(db_path).ok();
    let cached = db
        .as_ref()
        .and_then(|db| db.fetch_lyrics(&track.title, &track.artist));
    if let Some(row) = cached
        .as_ref()
        .filter(|row| is_current(row) && has_content(row))
    {
        return found_or_missing(lyrics_from_row(row));
    }
    let offset_ms = cached.as_ref().map_or(0, |row| row.offset_ms);

    if let Some(local) = read_local(&music_root.join(&track.rel_path)) {
        let content = LyricsContent {
            synced: local.synced_raw.clone(),
            plain: local.plain.clone(),
            lyricsfile: None,
            instrumental: false,
            revision: REVISION,
        };
        if let Some(db) = &db {
            let _ = db.save_lyrics(&track.title, &track.artist, &content);
        }
        return found_or_missing(Lyrics {
            document: document_from(local.synced_raw.as_deref(), local.plain.as_deref(), None, false),
            offset_ms,
        });
    }
    if cached.as_ref().is_some_and(is_current) {
        return LyricsResult::Missing;
    }

    let stale = cached.as_ref().filter(|row| has_content(row));
    match lookup_remote(track) {
        Remote::Found(fetched) => {
            let content = LyricsContent {
                synced: fetched.synced.clone(),
                plain: fetched.plain.clone(),
                lyricsfile: fetched.lyricsfile.clone(),
                instrumental: fetched.instrumental,
                revision: REVISION,
            };
            if let Some(db) = &db {
                let _ = db.save_lyrics(&track.title, &track.artist, &content);
            }
            found_or_missing(Lyrics {
                document: document_from(
                    fetched.synced.as_deref(),
                    fetched.plain.as_deref(),
                    fetched.lyricsfile.as_deref(),
                    fetched.instrumental,
                ),
                offset_ms,
            })
        }
        Remote::Missing => match stale {
            Some(row) => {
                if let Some(db) = &db {
                    let _ = db.set_lyrics_revision(&track.title, &track.artist, REVISION);
                }
                found_or_missing(lyrics_from_row(row))
            }
            None => {
                if let Some(db) = &db {
                    let _ = db.save_lyrics(
                        &track.title,
                        &track.artist,
                        &LyricsContent {
                            synced: None,
                            plain: None,
                            lyricsfile: None,
                            instrumental: false,
                            revision: REVISION,
                        },
                    );
                }
                crate::logger::info(
                    "lyrics",
                    &format!(
                        "no lyrics for {} — {} (cached miss)",
                        track.title, track.artist
                    ),
                );
                LyricsResult::Missing
            }
        },
        Remote::Failed(failure) => match stale {
            Some(row) => found_or_missing(lyrics_from_row(row)),
            None => LyricsResult::Failed(failure),
        },
    }
}

/// Remembers the listener's timing correction for a track's lyrics.
pub fn save_offset(db_path: &Path, track: &Track, offset_ms: i64) {
    if let Ok(db) = Db::open(db_path) {
        let _ = db.save_lyrics_offset(&track.title, &track.artist, offset_ms);
    }
}

struct Fetched {
    synced: Option<String>,
    plain: Option<String>,
    lyricsfile: Option<String>,
    instrumental: bool,
}

enum Remote {
    Found(Fetched),
    Missing,
    Failed(LyricsFailure),
}

enum Reply {
    Body(String),
    NotFound,
    Failed(LyricsFailure),
}

/// lrclib's exact-match endpoint is strict about the album name and about the
/// title as tagged, which are the commonest causes of a false 404. So: try the
/// full signature, then drop the album, then the title and artist with edition
/// decoration and featuring credits removed, then the fuzzy search endpoint,
/// ranking its results here (the endpoint itself is duration-blind).
fn lookup_remote(track: &Track) -> Remote {
    let agent = ureq::AgentBuilder::new().timeout(REQUEST_TIMEOUT).build();
    let ua = user_agent();
    let title = clean_title(&track.title);
    let artist = lead_artist(&track.artist);

    let mut attempts: Vec<(&str, &str, Option<&str>)> = Vec::new();
    if !track.album.trim().is_empty() {
        attempts.push((&track.title, &track.artist, Some(&track.album)));
    }
    attempts.push((&track.title, &track.artist, None));
    if title != track.title || artist != track.artist {
        attempts.push((&title, &artist, None));
    }
    for (attempt_title, attempt_artist, album) in attempts {
        match get_exact(&agent, &ua, attempt_title, attempt_artist, album, track.duration) {
            Remote::Missing => {}
            other => return other,
        }
    }
    search_fallback(&agent, &ua, track, &title, &artist)
}

fn get_exact(
    agent: &ureq::Agent,
    ua: &str,
    title: &str,
    artist: &str,
    album: Option<&str>,
    duration: f64,
) -> Remote {
    let mut url = format!(
        "https://lrclib.net/api/get?track_name={}&artist_name={}",
        url_encode(title),
        url_encode(artist)
    );
    if let Some(album) = album {
        url.push_str(&format!("&album_name={}", url_encode(album)));
    }
    if duration > 0.0 {
        url.push_str(&format!("&duration={}", duration.round() as i64));
    }
    match request(agent, ua, &url) {
        Reply::Body(body) => parse_record(&body).unwrap_or(Remote::Missing),
        Reply::NotFound => Remote::Missing,
        Reply::Failed(failure) => Remote::Failed(failure),
    }
}

fn search_fallback(
    agent: &ureq::Agent,
    ua: &str,
    track: &Track,
    title: &str,
    artist: &str,
) -> Remote {
    let url = format!(
        "https://lrclib.net/api/search?track_name={}&artist_name={}",
        url_encode(title),
        url_encode(artist)
    );
    let body = match request(agent, ua, &url) {
        Reply::Body(body) => body,
        Reply::NotFound => return Remote::Missing,
        Reply::Failed(failure) => return Remote::Failed(failure),
    };
    let Ok(records) = serde_json::from_str::<Vec<serde_json::Value>>(&body) else {
        return Remote::Missing;
    };
    let titles: Vec<String> = records
        .iter()
        .map(|record| clean_title(record["trackName"].as_str().unwrap_or_default()))
        .collect();
    let artists: Vec<String> = records
        .iter()
        .map(|record| lead_artist(record["artistName"].as_str().unwrap_or_default()))
        .collect();
    let candidates: Vec<Candidate> = records
        .iter()
        .enumerate()
        .map(|(index, record)| Candidate {
            title: &titles[index],
            artist: &artists[index],
            album: record["albumName"].as_str().unwrap_or_default(),
            duration: record["duration"].as_f64().unwrap_or(0.0),
            has_synced: is_filled(record["syncedLyrics"].as_str()),
            has_word_sync: record["hasWordSync"].as_bool().unwrap_or(false),
        })
        .collect();
    let wanted = Wanted {
        title,
        artist,
        album: &track.album,
        duration: track.duration,
    };
    match best_candidate(&wanted, &candidates) {
        Some((index, score)) => {
            crate::logger::info(
                "lyrics",
                &format!(
                    "lrclib search matched {} — {} (score {score:.2})",
                    track.title, track.artist
                ),
            );
            record_from_value(&records[index]).unwrap_or(Remote::Missing)
        }
        None => Remote::Missing,
    }
}

/// One GET, retried once when the server is overloaded or throttling, waiting
/// as long as it asks within reason. A 404 is an answer, not a failure.
fn request(agent: &ureq::Agent, ua: &str, url: &str) -> Reply {
    let mut last_failure = LyricsFailure::Unreachable;
    for attempt in 0..2 {
        match agent.get(url).set("User-Agent", ua).call() {
            Ok(response) => {
                return response
                    .into_string()
                    .map(Reply::Body)
                    .unwrap_or(Reply::Failed(LyricsFailure::Unreachable));
            }
            Err(ureq::Error::Status(404, _)) => return Reply::NotFound,
            Err(ureq::Error::Status(code, response))
                if attempt == 0 && (code == 429 || code >= 500) =>
            {
                let wait = response
                    .header("Retry-After")
                    .and_then(|value| value.trim().parse::<f64>().ok())
                    .unwrap_or(DEFAULT_RETRY_WAIT)
                    .clamp(SHORTEST_RETRY_WAIT, LONGEST_RETRY_WAIT);
                last_failure = LyricsFailure::from_status(code);
                std::thread::sleep(Duration::from_secs_f64(wait));
            }
            Err(err) => {
                crate::logger::warn("lyrics", &format!("lrclib request failed: {err}"));
                return Reply::Failed(failure_of(&err));
            }
        }
    }
    Reply::Failed(last_failure)
}

/// What a transport or status error from lrclib means to the listener.
fn failure_of(err: &ureq::Error) -> LyricsFailure {
    match err {
        ureq::Error::Status(code, _) => LyricsFailure::from_status(*code),
        ureq::Error::Transport(transport) => {
            let timed_out = std::error::Error::source(transport)
                .and_then(|source| source.downcast_ref::<std::io::Error>())
                .is_some_and(|io| {
                    matches!(
                        io.kind(),
                        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                    )
                });
            if timed_out {
                LyricsFailure::TimedOut
            } else {
                LyricsFailure::Unreachable
            }
        }
    }
}

fn parse_record(body: &str) -> Option<Remote> {
    let value = serde_json::from_str::<serde_json::Value>(body).ok()?;
    record_from_value(&value)
}

fn record_from_value(value: &serde_json::Value) -> Option<Remote> {
    let text = |key: &str| {
        value[key]
            .as_str()
            .filter(|text| !text.trim().is_empty())
            .map(str::to_string)
    };
    let fetched = Fetched {
        synced: text("syncedLyrics"),
        plain: text("plainLyrics"),
        lyricsfile: text("lyricsfile"),
        instrumental: value["instrumental"].as_bool().unwrap_or(false),
    };
    if fetched.synced.is_none() && fetched.plain.is_none() && !fetched.instrumental {
        return Some(Remote::Missing);
    }
    Some(Remote::Found(fetched))
}

struct LocalLyrics {
    synced_raw: Option<String>,
    plain: Option<String>,
}

/// Lyrics the user curated themselves, in the order other players look: an
/// `.lrc`/`.elrc` sidecar next to the audio, then the file's own tags. Never
/// written back — the library is the user's.
fn read_local(path: &Path) -> Option<LocalLyrics> {
    for extension in ["lrc", "elrc"] {
        let sidecar = path.with_extension(extension);
        if let Ok(text) = std::fs::read_to_string(&sidecar) {
            if !text.trim().is_empty() {
                crate::logger::info("lyrics", &format!("using sidecar {}", sidecar.display()));
                return Some(classify_local(&text));
            }
        }
    }
    read_tagged_lyrics(path).map(|text| classify_local(&text))
}

/// Text with timestamps is synchronized lyrics (word tags and all, so a
/// timed file keeps its words); anything else is plain.
fn classify_local(text: &str) -> LocalLyrics {
    if parse_lrc(text).has_synced() {
        LocalLyrics {
            synced_raw: Some(text.to_string()),
            plain: None,
        }
    } else {
        LocalLyrics {
            synced_raw: None,
            plain: Some(text.to_string()),
        }
    }
}

fn read_tagged_lyrics(path: &Path) -> Option<String> {
    use lofty::file::TaggedFileExt;
    use lofty::prelude::{Accessor, ItemKey};
    use lofty::probe::Probe;

    let tagged = Probe::open(path).ok()?.read().ok()?;
    let tags: Vec<_> = tagged
        .primary_tag()
        .into_iter()
        .chain(tagged.tags().iter())
        .collect();
    for tag in tags {
        for key in [
            ItemKey::Lyrics,
            ItemKey::Unknown("SYNCEDLYRICS".to_string()),
            ItemKey::Unknown("UNSYNCEDLYRICS".to_string()),
            ItemKey::Unknown("LYRICS".to_string()),
        ] {
            if let Some(text) = tag.get_string(&key).filter(|text| !text.trim().is_empty()) {
                return Some(text.to_string());
            }
        }
        if let Some(text) = tag.comment().filter(|text| text.contains("[00:")) {
            return Some(text.to_string());
        }
    }
    None
}

fn url_encode(input: &str) -> String {
    let mut result = String::new();
    for byte in input.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                result.push(*byte as char)
            }
            _ => result.push_str(&format!("%{:02X}", byte)),
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    const LYRICSFILE: &str = "version: '1.0'\nmetadata:\n  title: t\n  artist: a\nlines:\n- text: Hello\n  start_ms: 1000\n  end_ms: 3000\n  words:\n  - text: 'Hel'\n    start_ms: 1000\n    end_ms: 2000\n  - text: lo\n    start_ms: 2000\n    end_ms: 3000\n";

    fn row(synced: Option<&str>, lyricsfile: Option<&str>, revision: i64) -> LyricsRow {
        LyricsRow {
            synced: synced.map(str::to_string),
            plain: None,
            lyricsfile: lyricsfile.map(str::to_string),
            instrumental: false,
            offset_ms: 0,
            revision,
            age_days: 0.0,
        }
    }

    #[test]
    fn a_readable_lyricsfile_beats_the_lrc_text() {
        let document = document_from(Some("[00:05.00]other"), None, Some(LYRICSFILE), false);
        assert!(document.has_word_sync());
        assert_eq!(document.lines.last().unwrap().text, "Hello");
    }

    #[test]
    fn an_unreadable_lyricsfile_falls_back_to_the_lrc_text() {
        let document = document_from(Some("[00:05.00]other"), None, Some("not: [yaml"), false);
        assert!(!document.has_word_sync());
        assert_eq!(document.lines.last().unwrap().text, "other");
    }

    #[test]
    fn plain_lyrics_ride_along_with_synced_ones() {
        let document = document_from(Some("[00:05.00]x"), Some("x\ny"), None, false);
        assert_eq!(document.plain.as_deref(), Some("x\ny"));
    }

    #[test]
    fn instrumental_wins_over_everything() {
        let document = document_from(Some("[00:05.00]x"), Some("x"), Some(LYRICSFILE), true);
        assert!(document.instrumental);
        assert!(document.lines.is_empty());
    }

    #[test]
    fn content_from_an_older_revision_is_asked_for_again() {
        assert!(!is_current(&row(Some("[00:01.00]x"), None, 0)));
        assert!(is_current(&row(Some("[00:01.00]x"), None, REVISION)));
    }

    #[test]
    fn a_miss_stands_for_thirty_days_whatever_its_revision() {
        let mut miss = row(None, None, 0);
        miss.age_days = 10.0;
        assert!(is_current(&miss));
        miss.age_days = 31.0;
        assert!(!is_current(&miss));
    }

    #[test]
    fn a_local_file_with_stamps_stays_synchronized_with_its_word_tags() {
        let local = classify_local("[00:05.00]<00:05.00>Hi <00:05.50>there");
        let document = document_from(local.synced_raw.as_deref(), None, None, false);
        assert!(document.has_word_sync());
        let unsynced = classify_local("just words\nno stamps");
        assert!(unsynced.synced_raw.is_none());
        assert_eq!(unsynced.plain.as_deref(), Some("just words\nno stamps"));
    }

    #[test]
    fn the_offset_moves_the_song_time_opposite_to_the_position() {
        let lyrics = Lyrics {
            document: parse_lrc("[00:10.00]a\n[00:20.00]b"),
            offset_ms: 500,
        };
        assert_eq!(lyrics.text_at(10.4), None);
        assert_eq!(lyrics.text_at(10.6), Some("a"));
        let earlier = Lyrics {
            offset_ms: -500,
            ..lyrics
        };
        assert_eq!(earlier.text_at(9.6), Some("a"));
    }

    fn scratch_dir(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("flaccy-lyrics-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn track(rel_path: &str) -> Track {
        Track {
            id: 1,
            rel_path: rel_path.to_string(),
            title: "Song".to_string(),
            artist: "Artist".to_string(),
            album: "Album".to_string(),
            album_artist: None,
            track_number: 1,
            duration: 100.0,
            codec: None,
            bit_depth: None,
            sample_rate: None,
            channels: None,
            loved: false,
            play_count: 0,
            date_added: 0,
            last_played: None,
            revision: 1,
            revised_at: None,
            file_modified_ms: None,
        }
    }

    #[test]
    fn a_cached_miss_does_not_hide_a_lrc_file_added_since() {
        let dir = scratch_dir("miss-then-sidecar");
        let db_path = dir.join("library.sqlite");
        let db = Db::open(&db_path).unwrap();
        db.save_lyrics(
            "Song",
            "Artist",
            &LyricsContent {
                synced: None,
                plain: None,
                lyricsfile: None,
                instrumental: false,
                revision: REVISION,
            },
        )
        .unwrap();
        drop(db);
        assert!(matches!(
            fetch_blocking(&db_path, &dir, &track("missing.flac")),
            LyricsResult::Missing
        ));
        std::fs::write(dir.join("song.lrc"), "[00:05.00]Hello there").unwrap();
        match fetch_blocking(&db_path, &dir, &track("song.flac")) {
            LyricsResult::Found(lyrics) => {
                assert_eq!(lyrics.document.lines.last().unwrap().text, "Hello there");
            }
            _ => panic!("the sidecar should have been read past the cached miss"),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
