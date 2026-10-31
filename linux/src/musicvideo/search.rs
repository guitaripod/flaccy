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
/// merged in behind it so songs whose video isn't labelled still surface. Both
/// go to one yt-dlp process, which saves a second interpreter start.
pub fn search(title: &str, artist: &str) -> SearchOutcome {
    let lead = crate::hygiene::primary_artist(artist);
    let song = super::score::search_title(title);
    let queries = [
        format!("{lead} {song} official music video"),
        format!("{lead} {song}"),
    ];
    match run_queries(&queries) {
        Ok(listings) => merge(listings),
        Err(err) => SearchOutcome::Failed(err),
    }
}

/// Folds the listings into one list in the order given, each video once.
fn merge(listings: Vec<Vec<Candidate>>) -> SearchOutcome {
    let mut merged: Vec<Candidate> = Vec::new();
    for candidate in listings.into_iter().flatten() {
        if !merged.iter().any(|existing| existing.id == candidate.id) {
            merged.push(candidate);
        }
    }
    if merged.is_empty() {
        SearchOutcome::Empty
    } else {
        SearchOutcome::Found(merged)
    }
}

fn run_queries(queries: &[String]) -> Result<Vec<Vec<Candidate>>, String> {
    let Some(yt_dlp) = resolve_tool("yt-dlp") else {
        return Err(super::YT_DLP_MISSING.to_string());
    };
    let output = Command::new(yt_dlp)
        .args(["--flat-playlist", "-J", "--no-warnings", "--ignore-config"])
        .args(["--socket-timeout", SEARCH_TIMEOUT_SECS])
        .args(
            queries
                .iter()
                .map(|query| format!("ytsearch{RESULTS_PER_QUERY}:{query}")),
        )
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|err| format!("could not start yt-dlp: {err}"))?;
    let listings = parse_listings(&output.stdout);
    if listings.is_empty() && !output.status.success() {
        return Err(crate::downloads::friendly_error(&String::from_utf8_lossy(
            &output.stderr,
        )));
    }
    if listings.is_empty() && !output.stdout.is_empty() {
        return Err("yt-dlp returned something unreadable".to_string());
    }
    Ok(listings)
}

/// With several URLs and `-J`, yt-dlp prints one JSON document per line. A
/// query that failed prints nothing, so the others still count.
fn parse_listings(stdout: &[u8]) -> Vec<Vec<Candidate>> {
    String::from_utf8_lossy(stdout)
        .lines()
        .filter(|line| line.trim_start().starts_with('{'))
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .map(|value| parse_entries(&value))
        .collect()
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
                || entry
                    .get("is_live")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
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

/// The watch page opened at a moment in the video, so "Open on YouTube"
/// carries on from what is on screen.
pub fn watch_url_at(video_id: &str, seconds: f64) -> String {
    let whole = seconds.max(0.0).floor() as u64;
    if whole == 0 {
        watch_url(video_id)
    } else {
        format!("{}&t={whole}s", watch_url(video_id))
    }
}

/// Picks the video id out of anything a person might paste: a watch page, a
/// short link, a Shorts or embed URL, a YouTube Music link, or the bare id.
pub fn video_id_from_link(text: &str) -> Option<String> {
    let text = text.trim();
    let valid = |id: &str| {
        id.len() == 11
            && id
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    };
    if valid(text) {
        return Some(text.to_string());
    }
    let without_scheme = text.split_once("://").map(|(_, rest)| rest).unwrap_or(text);
    let (host, rest) = without_scheme.split_once('/')?;
    let host = host.trim_start_matches("www.").trim_start_matches("m.");
    let (path, query) = rest.split_once('?').unwrap_or((rest, ""));
    let candidate = match host {
        "youtu.be" => path.split('/').next().map(str::to_string),
        "youtube.com" | "music.youtube.com" | "youtube-nocookie.com" => {
            let from_query = query
                .split(['&', '#'])
                .filter_map(|pair| pair.split_once('='))
                .find(|(key, _)| *key == "v")
                .map(|(_, value)| value.to_string());
            from_query.or_else(|| {
                let mut parts = path.split('/');
                match parts.next() {
                    Some("shorts" | "embed" | "live" | "v") => parts.next().map(str::to_string),
                    _ => None,
                }
            })
        }
        _ => None,
    }?;
    let candidate = candidate.split(['#', '&']).next()?.to_string();
    valid(&candidate).then_some(candidate)
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
    fn reads_one_listing_per_line_and_merges_them_in_order() {
        let stdout = br#"{"entries":[{"id":"a","title":"Song (Official Video)","channel":"Band"},{"id":"b","title":"Song (Lyrics)","channel":"x"}]}
{"entries":[{"id":"b","title":"Song (Lyrics)","channel":"x"},{"id":"c","title":"Song","channel":"Band - Topic"}]}
"#;
        let listings = parse_listings(stdout);
        assert_eq!(listings.len(), 2);
        let SearchOutcome::Found(merged) = merge(listings) else {
            panic!("expected results");
        };
        let ids: Vec<&str> = merged.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids, ["a", "b", "c"]);
        assert!(matches!(merge(Vec::new()), SearchOutcome::Empty));
        assert!(parse_listings(b"ERROR: nope\n").is_empty());
    }

    #[test]
    fn builds_watch_urls() {
        assert_eq!(
            watch_url("a5uQMwRMHcs"),
            "https://www.youtube.com/watch?v=a5uQMwRMHcs"
        );
        assert_eq!(
            watch_url_at("a5uQMwRMHcs", 83.7),
            "https://www.youtube.com/watch?v=a5uQMwRMHcs&t=83s"
        );
        assert_eq!(watch_url_at("a5uQMwRMHcs", -2.0), watch_url("a5uQMwRMHcs"));
    }

    #[test]
    fn finds_the_video_in_any_kind_of_link() {
        let id = Some("a5uQMwRMHcs".to_string());
        for link in [
            "a5uQMwRMHcs",
            "https://www.youtube.com/watch?v=a5uQMwRMHcs",
            "https://www.youtube.com/watch?list=PL1&v=a5uQMwRMHcs&t=12s",
            "youtube.com/watch?v=a5uQMwRMHcs",
            "https://youtu.be/a5uQMwRMHcs?si=abc",
            "https://m.youtube.com/watch?v=a5uQMwRMHcs#t=3",
            "https://music.youtube.com/watch?v=a5uQMwRMHcs&feature=share",
            "https://www.youtube.com/shorts/a5uQMwRMHcs",
            "https://www.youtube.com/embed/a5uQMwRMHcs",
            "  https://youtu.be/a5uQMwRMHcs  ",
        ] {
            assert_eq!(video_id_from_link(link), id, "{link}");
        }
        for junk in [
            "",
            "Instant Crush",
            "https://vimeo.com/123456789",
            "https://www.youtube.com/channel/UC123",
            "https://www.youtube.com/watch?v=short",
        ] {
            assert_eq!(video_id_from_link(junk), None, "{junk}");
        }
    }
}
