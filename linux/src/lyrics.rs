use crate::db::Db;
use crate::library::Track;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Clone, Default)]
pub struct Lyrics {
    pub synced: Vec<(f64, String)>,
    pub plain: Option<String>,
    pub instrumental: bool,
}

impl Lyrics {
    fn is_empty(&self) -> bool {
        !self.instrumental
            && self.synced.is_empty()
            && self.plain.as_deref().map(str::trim).unwrap_or("").is_empty()
    }
}

/// Distinguishes "lrclib has nothing for this track" from "we couldn't ask".
/// A miss is cached (and expires); a failure is not, so a flaky network never
/// leaves a permanently blank panel.
#[derive(Clone)]
pub enum LyricsResult {
    Found(Lyrics),
    Missing,
    Failed,
}

/// How long a remembered miss stands before lrclib is asked again — the corpus
/// is community-contributed and grows.
const MISS_TTL_DAYS: f64 = 30.0;
/// Two pressings of the same song can differ by a few seconds; beyond this the
/// timings would be useless, so a search candidate is rejected outright.
const MAX_DURATION_DRIFT: f64 = 15.0;

fn user_agent() -> String {
    format!(
        "flaccy/{} (https://github.com/guitaripod/flaccy)",
        env!("CARGO_PKG_VERSION")
    )
}

/// Warms the cache for a track without rendering anything, so opening the
/// lyrics panel on the song already playing is instant.
pub fn prefetch(db_path: &Path, music_root: &Path, track: &Track) {
    let db_path = db_path.to_path_buf();
    let music_root = music_root.to_path_buf();
    let track = track.clone();
    std::thread::Builder::new()
        .name("flaccy-lyrics-prefetch".into())
        .spawn(move || {
            let cached = Db::open(&db_path)
                .ok()
                .and_then(|db| db.fetch_lyrics(&track.title, &track.artist));
            if cached.is_some_and(|row| !is_stale_miss(&row)) {
                return;
            }
            let _ = fetch_blocking(&db_path, &music_root, &track);
        })
        .ok();
}

fn is_stale_miss(row: &crate::db::LyricsRow) -> bool {
    let empty = !row.instrumental
        && row.synced.as_deref().map(str::trim).unwrap_or("").is_empty()
        && row.plain.as_deref().map(str::trim).unwrap_or("").is_empty();
    empty && row.age_days > MISS_TTL_DAYS
}

/// Resolution order: the local database cache, then lyrics the user keeps
/// alongside the audio (`.lrc` sidecar or an embedded tag), then lrclib.
pub fn fetch_blocking(db_path: &PathBuf, music_root: &Path, track: &Track) -> LyricsResult {
    let db = match Db::open(db_path) {
        Ok(db) => db,
        Err(_) => return LyricsResult::Failed,
    };
    if let Some(cached) = db.fetch_lyrics(&track.title, &track.artist) {
        if !is_stale_miss(&cached) {
            let lyrics = Lyrics {
                synced: cached.synced.as_deref().map(parse_lrc).unwrap_or_default(),
                plain: cached.plain,
                instrumental: cached.instrumental,
            };
            return if lyrics.is_empty() {
                LyricsResult::Missing
            } else {
                LyricsResult::Found(lyrics)
            };
        }
    }

    if let Some(local) = read_local(&music_root.join(&track.rel_path)) {
        let _ = db.save_lyrics(
            &track.title,
            &track.artist,
            local.synced_raw.as_deref(),
            local.plain.as_deref(),
            false,
        );
        return LyricsResult::Found(Lyrics {
            synced: local.synced_raw.as_deref().map(parse_lrc).unwrap_or_default(),
            plain: local.plain,
            instrumental: false,
        });
    }

    match lookup_remote(track) {
        Remote::Found { synced, plain, instrumental } => {
            let _ = db.save_lyrics(
                &track.title,
                &track.artist,
                synced.as_deref(),
                plain.as_deref(),
                instrumental,
            );
            LyricsResult::Found(Lyrics {
                synced: synced.as_deref().map(parse_lrc).unwrap_or_default(),
                plain,
                instrumental,
            })
        }
        Remote::Missing => {
            let _ = db.save_lyrics(&track.title, &track.artist, None, None, false);
            crate::logger::info(
                "lyrics",
                &format!("no lyrics for {} — {} (cached miss)", track.title, track.artist),
            );
            LyricsResult::Missing
        }
        Remote::Failed => LyricsResult::Failed,
    }
}

enum Remote {
    Found {
        synced: Option<String>,
        plain: Option<String>,
        instrumental: bool,
    },
    Missing,
    Failed,
}

/// lrclib's exact-match endpoint is strict about the album name, which is the
/// single most common cause of a false 404. So: try the full signature, then
/// drop the album, then fall back to the fuzzy search endpoint and rank its
/// results here (the endpoint itself is duration-blind).
fn lookup_remote(track: &Track) -> Remote {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(10))
        .build();
    let ua = user_agent();

    match get_exact(&agent, &ua, track, true) {
        Remote::Missing => {}
        other => return other,
    }
    if !track.album.trim().is_empty() {
        match get_exact(&agent, &ua, track, false) {
            Remote::Missing => {}
            other => return other,
        }
    }
    search_fallback(&agent, &ua, track)
}

fn get_exact(agent: &ureq::Agent, ua: &str, track: &Track, with_album: bool) -> Remote {
    let mut url = format!(
        "https://lrclib.net/api/get?track_name={}&artist_name={}",
        url_encode(&track.title),
        url_encode(&track.artist)
    );
    if with_album && !track.album.trim().is_empty() {
        url.push_str(&format!("&album_name={}", url_encode(&track.album)));
    }
    if track.duration > 0.0 {
        url.push_str(&format!("&duration={}", track.duration.round() as i64));
    }
    match agent.get(&url).set("User-Agent", ua).call() {
        Ok(response) => match response.into_string().ok().and_then(parse_record) {
            Some(record) => record,
            None => Remote::Missing,
        },
        Err(ureq::Error::Status(404, _)) => Remote::Missing,
        Err(err) => {
            crate::logger::warn("lyrics", &format!("lrclib request failed: {err}"));
            Remote::Failed
        }
    }
}

fn search_fallback(agent: &ureq::Agent, ua: &str, track: &Track) -> Remote {
    let url = format!(
        "https://lrclib.net/api/search?track_name={}&artist_name={}",
        url_encode(&track.title),
        url_encode(&track.artist)
    );
    let body = match agent.get(&url).set("User-Agent", ua).call() {
        Ok(response) => match response.into_string() {
            Ok(body) => body,
            Err(_) => return Remote::Failed,
        },
        Err(ureq::Error::Status(404, _)) => return Remote::Missing,
        Err(err) => {
            crate::logger::warn("lyrics", &format!("lrclib search failed: {err}"));
            return Remote::Failed;
        }
    };
    let Ok(candidates) = serde_json::from_str::<Vec<serde_json::Value>>(&body) else {
        return Remote::Missing;
    };
    let best = candidates
        .iter()
        .filter_map(|value| score_candidate(track, value).map(|score| (score, value)))
        .max_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    match best {
        Some((score, value)) if score >= 0.80 => {
            crate::logger::info(
                "lyrics",
                &format!(
                    "lrclib search matched {} — {} (score {score:.2})",
                    track.title, track.artist
                ),
            );
            record_from_value(value).unwrap_or(Remote::Missing)
        }
        _ => Remote::Missing,
    }
}

/// Weighted similarity across the fields lrclib returns. Duration carries real
/// weight because it is what distinguishes pressings whose timings differ, and
/// a large drift disqualifies a candidate outright.
fn score_candidate(track: &Track, value: &serde_json::Value) -> Option<f64> {
    let title = value["trackName"].as_str().unwrap_or_default();
    let artist = value["artistName"].as_str().unwrap_or_default();
    let album = value["albumName"].as_str().unwrap_or_default();
    let duration = value["duration"].as_f64().unwrap_or(0.0);
    if track.duration > 0.0 && duration > 0.0 && (track.duration - duration).abs() > MAX_DURATION_DRIFT
    {
        return None;
    }
    let duration_score = if track.duration > 0.0 && duration > 0.0 {
        1.0 - ((track.duration - duration).abs() / MAX_DURATION_DRIFT).min(1.0)
    } else {
        0.5
    };
    let has_synced = value["syncedLyrics"].as_str().is_some_and(|s| !s.trim().is_empty());
    Some(
        0.35 * similarity(&track.title, title)
            + 0.30 * similarity(&track.artist, artist)
            + 0.25 * duration_score
            + 0.06 * if has_synced { 1.0 } else { 0.0 }
            + 0.04 * similarity(&track.album, album),
    )
}

/// Case- and punctuation-insensitive token overlap (Dice coefficient over
/// words), enough to tell "Song (Remastered 2011)" from a different song.
fn similarity(left: &str, right: &str) -> f64 {
    let tokens = |text: &str| -> Vec<String> {
        text.to_lowercase()
            .split(|c: char| !c.is_alphanumeric())
            .filter(|part| !part.is_empty())
            .map(|part| part.to_string())
            .collect()
    };
    let (left, right) = (tokens(left), tokens(right));
    if left.is_empty() || right.is_empty() {
        return 0.0;
    }
    let shared = left.iter().filter(|token| right.contains(token)).count();
    2.0 * shared as f64 / (left.len() + right.len()) as f64
}

fn parse_record(body: String) -> Option<Remote> {
    let value = serde_json::from_str::<serde_json::Value>(&body).ok()?;
    record_from_value(&value)
}

fn record_from_value(value: &serde_json::Value) -> Option<Remote> {
    let synced = value["syncedLyrics"]
        .as_str()
        .filter(|text| !text.trim().is_empty())
        .map(str::to_string);
    let plain = value["plainLyrics"]
        .as_str()
        .filter(|text| !text.trim().is_empty())
        .map(str::to_string);
    let instrumental = value["instrumental"].as_bool().unwrap_or(false);
    if synced.is_none() && plain.is_none() && !instrumental {
        return Some(Remote::Missing);
    }
    Some(Remote::Found { synced, plain, instrumental })
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

fn classify_local(text: &str) -> LocalLyrics {
    let text = strip_word_timestamps(text);
    if parse_lrc(&text).is_empty() {
        LocalLyrics { synced_raw: None, plain: Some(text) }
    } else {
        LocalLyrics { synced_raw: Some(text), plain: None }
    }
}

/// Enhanced-LRC files carry per-word `<mm:ss.xx>` tags inside each line. The
/// panel highlights whole lines, so the word tags are removed rather than
/// mistaken for lyrics.
fn strip_word_timestamps(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut depth = 0usize;
    for ch in text.chars() {
        match ch {
            '<' => depth += 1,
            '>' if depth > 0 => depth -= 1,
            _ if depth == 0 => out.push(ch),
            _ => {}
        }
    }
    out
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

pub fn parse_lrc(text: &str) -> Vec<(f64, String)> {
    let mut lines: Vec<(f64, String)> = Vec::new();
    for raw_line in text.lines() {
        let mut rest = raw_line.trim_start();
        let mut stamps: Vec<f64> = Vec::new();
        while let Some(close) = rest.find(']') {
            if !rest.starts_with('[') {
                break;
            }
            let tag = &rest[1..close];
            match parse_timestamp(tag) {
                Some(stamp) => stamps.push(stamp),
                None => break,
            }
            rest = &rest[close + 1..];
        }
        let content = rest.trim().to_string();
        for stamp in stamps {
            lines.push((stamp, content.clone()));
        }
    }
    lines.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    lines
}

/// Accepts `[mm:ss]`, `[mm:ss.xx]`, `[mm:ss:xx]` and `[hh:mm:ss.xx]` — all four
/// appear in files in the wild, and rejecting one silently drops the whole set.
fn parse_timestamp(tag: &str) -> Option<f64> {
    let tag = tag.trim();
    let parts: Vec<&str> = tag.split(':').collect();
    let seconds = |text: &str| -> Option<f64> { text.replace(',', ".").parse::<f64>().ok() };
    match parts.len() {
        2 => Some(parts[0].parse::<f64>().ok()? * 60.0 + seconds(parts[1])?),
        3 => {
            let first: f64 = parts[0].parse().ok()?;
            let second: f64 = parts[1].parse().ok()?;
            // `mm:ss:xx` uses the third field as hundredths; `hh:mm:ss` does not.
            if parts[2].len() <= 2 && second < 60.0 && first < 60.0 && parts[0].len() <= 2 {
                let fraction: f64 = parts[2].parse().ok()?;
                Some(first * 60.0 + second + fraction / 100.0)
            } else {
                Some(first * 3600.0 + second * 60.0 + seconds(parts[2])?)
            }
        }
        _ => None,
    }
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

    #[test]
    fn parses_every_timestamp_shape() {
        assert_eq!(parse_timestamp("01:30"), Some(90.0));
        assert_eq!(parse_timestamp("01:30.50"), Some(90.5));
        assert_eq!(parse_timestamp("01:30:50"), Some(90.5));
        assert_eq!(parse_timestamp("01:02:03.5"), Some(3723.5));
        assert_eq!(parse_timestamp("ti"), None);
    }

    #[test]
    fn strips_enhanced_word_tags() {
        let text = "[00:12.00]<00:12.00>Hello <00:12.50>world";
        assert_eq!(parse_lrc(&strip_word_timestamps(text)), vec![(12.0, "Hello world".to_string())]);
    }

    #[test]
    fn repeated_timestamps_expand_to_one_line_each() {
        let lines = parse_lrc("[00:10.00][01:10.00]Chorus");
        assert_eq!(lines, vec![(10.0, "Chorus".into()), (70.0, "Chorus".into())]);
    }

    #[test]
    fn duration_drift_disqualifies_a_candidate() {
        let track = track_with_duration(200.0);
        let candidate = serde_json::json!({
            "trackName": "Song", "artistName": "Artist", "albumName": "Album", "duration": 400.0
        });
        assert!(score_candidate(&track, &candidate).is_none());
    }

    #[test]
    fn exact_match_scores_above_the_accept_threshold() {
        let track = track_with_duration(200.0);
        let candidate = serde_json::json!({
            "trackName": "Song", "artistName": "Artist", "albumName": "Album",
            "duration": 200.0, "syncedLyrics": "[00:01.00]hi"
        });
        assert!(score_candidate(&track, &candidate).unwrap() >= 0.80);
    }

    #[test]
    fn a_different_song_scores_below_the_threshold() {
        let track = track_with_duration(200.0);
        let candidate = serde_json::json!({
            "trackName": "Something Else Entirely", "artistName": "Other Band",
            "albumName": "Nope", "duration": 199.0
        });
        assert!(score_candidate(&track, &candidate).unwrap() < 0.80);
    }

    fn track_with_duration(duration: f64) -> Track {
        Track {
            id: 0,
            rel_path: "Artist/Album/01.flac".into(),
            title: "Song".into(),
            artist: "Artist".into(),
            album: "Album".into(),
            track_number: 1,
            duration,
            codec: None,
            bit_depth: None,
            sample_rate: None,
            channels: None,
            loved: false,
            play_count: 0,
            date_added: 0,
            last_played: None,
        }
    }
}
