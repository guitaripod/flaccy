use crate::db::Db;
use std::path::PathBuf;
use std::time::Duration;

#[derive(Clone, Default)]
pub struct Lyrics {
    pub synced: Vec<(f64, String)>,
    pub plain: Option<String>,
    pub instrumental: bool,
}


pub fn fetch_blocking(db_path: &PathBuf, title: &str, artist: &str, album: &str) -> Lyrics {
    let db = match Db::open(db_path) {
        Ok(db) => db,
        Err(_) => return Lyrics::default(),
    };
    if let Some(cached) = db.fetch_lyrics(title, artist) {
        return Lyrics {
            synced: cached
                .synced
                .as_deref()
                .map(parse_lrc)
                .unwrap_or_default(),
            plain: cached.plain,
            instrumental: cached.instrumental,
        };
    }

    let url = format!(
        "https://lrclib.net/api/get?track_name={}&artist_name={}&album_name={}",
        url_encode(title),
        url_encode(artist),
        url_encode(album)
    );
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(10))
        .build();
    let response = agent.get(&url).set("User-Agent", "flaccy/1.0").call();

    match response {
        Ok(resp) => {
            let Ok(text) = resp.into_string() else {
                return Lyrics::default();
            };
            let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) else {
                return Lyrics::default();
            };
            let synced_raw = json["syncedLyrics"].as_str().map(|s| s.to_string());
            let plain_raw = json["plainLyrics"].as_str().map(|s| s.to_string());
            let instrumental = json["instrumental"].as_bool().unwrap_or(false);
            let _ = db.save_lyrics(
                title,
                artist,
                synced_raw.as_deref(),
                plain_raw.as_deref(),
                instrumental,
            );
            Lyrics {
                synced: synced_raw.as_deref().map(parse_lrc).unwrap_or_default(),
                plain: plain_raw,
                instrumental,
            }
        }
        Err(ureq::Error::Status(404, _)) => {
            let _ = db.save_lyrics(title, artist, None, None, false);
            crate::logger::info("lyrics", &format!("no lyrics for {title} — {artist} (cached miss)"));
            Lyrics::default()
        }
        Err(err) => {
            crate::logger::warn("lyrics", &format!("lrclib request failed: {err}"));
            Lyrics::default()
        }
    }
}

pub fn parse_lrc(text: &str) -> Vec<(f64, String)> {
    let mut lines: Vec<(f64, String)> = Vec::new();
    for raw_line in text.lines() {
        let mut rest = raw_line;
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

fn parse_timestamp(tag: &str) -> Option<f64> {
    let (minutes, seconds) = tag.split_once(':')?;
    let minutes: f64 = minutes.parse().ok()?;
    let seconds: f64 = seconds.parse().ok()?;
    Some(minutes * 60.0 + seconds)
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
