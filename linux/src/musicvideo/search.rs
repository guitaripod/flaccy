use super::Candidate;
use crate::downloads::resolve_tool;
use std::process::{Command, Stdio};

/// How many results each phrasing brings back. Enough that the real video is
/// almost always in there, few enough that a flat search stays under a second.
const RESULTS_PER_QUERY: usize = 8;

const SEARCH_TIMEOUT_SECS: &str = "20";

pub enum SearchOutcome {
    Found(Vec<Candidate>),
    /// yt-dlp answered and had nothing — a real "this song has no video".
    Empty,
    /// yt-dlp is missing, was blocked, or the network failed. Never cached as
    /// a miss, so a flaky moment doesn't permanently blank the video lens.
    Failed(String),
}

/// Searches YouTube for a track's music video. The explicit phrasing runs
/// first because it puts official uploads at the top; the bare phrasing is
/// merged in behind it so songs whose video isn't labelled still surface.
pub fn search(title: &str, artist: &str) -> SearchOutcome {
    let lead = crate::hygiene::primary_artist(artist);
    let song = super::score::search_title(title);
    let queries = [
        format!("{lead} {song} official music video"),
        format!("{lead} {song}"),
    ];

    let mut merged: Vec<Candidate> = Vec::new();
    let mut last_error: Option<String> = None;
    for query in queries {
        match run_query(&query) {
            Ok(found) => {
                for candidate in found {
                    if !merged.iter().any(|existing| existing.id == candidate.id) {
                        merged.push(candidate);
                    }
                }
            }
            Err(err) => last_error = Some(err),
        }
    }

    if !merged.is_empty() {
        return SearchOutcome::Found(merged);
    }
    match last_error {
        Some(err) => SearchOutcome::Failed(err),
        None => SearchOutcome::Empty,
    }
}

fn run_query(query: &str) -> Result<Vec<Candidate>, String> {
    let Some(yt_dlp) = resolve_tool("yt-dlp") else {
        return Err("yt-dlp is not installed".to_string());
    };
    let output = Command::new(yt_dlp)
        .args(["--flat-playlist", "-J", "--no-warnings", "--ignore-config"])
        .args(["--socket-timeout", SEARCH_TIMEOUT_SECS])
        .arg(format!("ytsearch{RESULTS_PER_QUERY}:{query}"))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|err| format!("could not start yt-dlp: {err}"))?;
    if !output.status.success() {
        return Err(crate::downloads::friendly_error(
            &String::from_utf8_lossy(&output.stderr),
        ));
    }
    let value: serde_json::Value = serde_json::from_slice(&output.stdout)
        .map_err(|_| "yt-dlp returned something unreadable".to_string())?;
    Ok(parse_entries(&value))
}

/// Reads yt-dlp's flat-playlist JSON. Fields missing from a flat listing are
/// treated as unknown rather than as zero, so a candidate is never rejected
/// for a runtime yt-dlp simply didn't report.
pub fn parse_entries(value: &serde_json::Value) -> Vec<Candidate> {
    let Some(entries) = value.get("entries").and_then(|e| e.as_array()) else {
        return Vec::new();
    };
    entries
        .iter()
        .filter_map(|entry| {
            let id = entry.get("id")?.as_str()?.to_string();
            if id.is_empty() {
                return None;
            }
            let title = entry
                .get("title")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string();
            if title.is_empty() || title == "[Private video]" || title == "[Deleted video]" {
                return None;
            }
            let channel = entry
                .get("channel")
                .or_else(|| entry.get("uploader"))
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string();
            let duration = entry
                .get("duration")
                .and_then(|v| v.as_f64())
                .unwrap_or(0.0);
            let view_count = entry.get("view_count").and_then(|v| v.as_u64());
            let live_now = entry
                .get("live_status")
                .and_then(|v| v.as_str())
                .map(|status| status == "is_live" || status == "is_upcoming")
                .unwrap_or(false)
                || entry.get("is_live").and_then(|v| v.as_bool()).unwrap_or(false);
            Some(Candidate {
                id,
                title,
                channel,
                duration,
                view_count,
                live_now,
            })
        })
        .collect()
}

pub fn watch_url(video_id: &str) -> String {
    format!("https://www.youtube.com/watch?v={video_id}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_flat_search_listing() {
        let value: serde_json::Value = serde_json::from_str(
            r#"{"entries":[
                {"id":"a5uQMwRMHcs","title":"Daft Punk - Instant Crush (Official Video)",
                 "channel":"Daft Punk","duration":340,"view_count":123,"live_status":"not_live"},
                {"id":"live1","title":"Tour Stream","channel":"Someone","duration":0,"live_status":"is_live"},
                {"id":"","title":"broken","channel":"x","duration":1},
                {"id":"p1","title":"[Private video]","channel":"x","duration":1}
            ]}"#,
        )
        .unwrap();
        let parsed = parse_entries(&value);
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].id, "a5uQMwRMHcs");
        assert_eq!(parsed[0].duration, 340.0);
        assert_eq!(parsed[0].view_count, Some(123));
        assert!(!parsed[0].live_now);
        assert!(parsed[1].live_now);
    }

    #[test]
    fn falls_back_to_uploader_when_channel_is_absent() {
        let value: serde_json::Value =
            serde_json::from_str(r#"{"entries":[{"id":"x1","title":"Song","uploader":"Band"}]}"#)
                .unwrap();
        let parsed = parse_entries(&value);
        assert_eq!(parsed[0].channel, "Band");
        assert_eq!(parsed[0].duration, 0.0);
    }

    #[test]
    fn a_listing_without_entries_yields_nothing() {
        let value: serde_json::Value = serde_json::from_str(r#"{"id":"single"}"#).unwrap();
        assert!(parse_entries(&value).is_empty());
    }

    #[test]
    fn builds_watch_urls() {
        assert_eq!(
            watch_url("a5uQMwRMHcs"),
            "https://www.youtube.com/watch?v=a5uQMwRMHcs"
        );
    }
}
