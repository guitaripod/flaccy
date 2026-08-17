use crate::downloads::{friendly_error, resolve_tool};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const RESOLVE_TIMEOUT_SECS: &str = "20";

/// Google's stream URLs carry their own expiry. Renewing a little early keeps
/// a long album from stalling on a URL that dies mid-song.
const EXPIRY_MARGIN_SECONDS: i64 = 300;

/// Used when the URL carries no expiry we can read, which is the case for
/// non-YouTube extractors.
const ASSUMED_LIFETIME_SECONDS: i64 = 1800;

#[derive(Clone)]
pub struct Stream {
    pub url: String,
    pub expires_at: i64,
    pub height: i32,
}

impl Stream {
    pub fn usable_at(&self, now: i64) -> bool {
        now + EXPIRY_MARGIN_SECONDS < self.expires_at
    }
}

/// Resolves a playable video-only stream. Audio is deliberately never
/// requested: the sound comes from the lossless file on disk, and a video-only
/// stream is both smaller and free of a second audio clock to fight with.
///
/// `strict` restricts the answer to H.264, the one codec every GStreamer
/// install can decode — the retry after a pipeline reports a missing plug-in.
pub fn resolve(video_id: &str, max_height: i32, now: i64, strict: bool) -> Result<Stream, String> {
    let Some(yt_dlp) = resolve_tool("yt-dlp") else {
        return Err("yt-dlp is not installed".to_string());
    };
    let format = format_selector(max_height, strict);
    let output = Command::new(yt_dlp)
        .args(["--no-warnings", "--ignore-config", "--no-playlist"])
        .args(["--socket-timeout", RESOLVE_TIMEOUT_SECS])
        .args(["-f", &format])
        .args(["--print", "%(urls)s|%(height)s"])
        .arg(super::search::watch_url(video_id))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|err| format!("could not start yt-dlp: {err}"))?;
    if !output.status.success() {
        return Err(friendly_error(&String::from_utf8_lossy(&output.stderr)));
    }
    let printed = String::from_utf8_lossy(&output.stdout);
    parse_resolved(&printed, now).ok_or_else(|| "no playable video stream".to_string())
}

/// Orders the acceptable formats by how certainly they can be decoded here.
/// Every clause demands a plain HTTP format: the same video is also offered as
/// HLS, whose segments need a transport-stream demuxer many installs lack, and
/// a single progressive URL is what the seek-driven sync wants anyway. H.264
/// comes first because every GStreamer install decodes it and most do so in
/// hardware; VP9 is the usual second; a muxed stream is the last resort, its
/// audio track simply ignored.
pub fn format_selector(max_height: i32, strict: bool) -> String {
    let http = format!("[protocol^=http][height<={max_height}]");
    if strict {
        return format!("bv*{http}[vcodec^=avc1]/b{http}[vcodec^=avc1]");
    }
    format!(
        "bv*{http}[vcodec^=avc1]/\
         bv*{http}[vcodec^=vp9]/\
         bv*{http}[ext=mp4]/\
         bv*{http}/\
         b{http}"
    )
}

/// Reads yt-dlp's `--print` line. A format whose URL is missing is treated as
/// no stream at all rather than as an empty one.
pub fn parse_resolved(printed: &str, now: i64) -> Option<Stream> {
    let line = printed.lines().map(str::trim).find(|line| !line.is_empty())?;
    let (url, height) = line.rsplit_once('|')?;
    let url = url.trim();
    if !url.starts_with("http") {
        return None;
    }
    Some(Stream {
        url: url.to_string(),
        expires_at: expiry_of(url).unwrap_or(now + ASSUMED_LIFETIME_SECONDS),
        height: height.trim().parse().unwrap_or(0),
    })
}

/// Pulls the `expire=` epoch out of a googlevideo URL.
pub fn expiry_of(url: &str) -> Option<i64> {
    let query = url.split_once('?')?.1;
    query
        .split('&')
        .filter_map(|pair| pair.split_once('='))
        .find(|(key, _)| *key == "expire")
        .and_then(|(_, value)| value.parse().ok())
}

/// Downloads the video's soundtrack so it can be correlated against the
/// library file. Only ever runs once per matched video — the offset it yields
/// is cached for good.
pub fn download_audio(video_id: &str, into: &Path) -> Option<PathBuf> {
    let yt_dlp = resolve_tool("yt-dlp")?;
    std::fs::create_dir_all(into).ok()?;
    let template = into.join(format!("{video_id}.%(ext)s"));
    let status = Command::new(yt_dlp)
        .args(["--no-warnings", "--ignore-config", "--no-playlist", "--quiet"])
        .args(["--socket-timeout", RESOLVE_TIMEOUT_SECS])
        .args(["-f", "ba[ext=m4a]/ba/b"])
        .arg("-o")
        .arg(&template)
        .arg(super::search::watch_url(video_id))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .ok()?;
    if !status.success() {
        return None;
    }
    std::fs::read_dir(into)
        .ok()?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .find(|path| {
            path.file_stem()
                .and_then(|stem| stem.to_str())
                .is_some_and(|stem| stem == video_id)
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_printed_stream_line() {
        let stream = parse_resolved(
            "https://rr2---sn-x.googlevideo.com/videoplayback?expire=1787021467&itag=136|720\n",
            1_786_999_000,
        )
        .unwrap();
        assert_eq!(stream.height, 720);
        assert_eq!(stream.expires_at, 1_787_021_467);
        assert!(stream.usable_at(1_786_999_000));
        assert!(!stream.usable_at(1_787_021_400));
    }

    #[test]
    fn a_url_without_an_expiry_gets_an_assumed_lifetime() {
        let stream = parse_resolved("https://example.com/video.mp4|1080", 1_000).unwrap();
        assert_eq!(stream.expires_at, 1_000 + ASSUMED_LIFETIME_SECONDS);
        assert_eq!(stream.height, 1080);
    }

    #[test]
    fn rejects_lines_that_are_not_urls() {
        assert!(parse_resolved("NA|720", 0).is_none());
        assert!(parse_resolved("", 0).is_none());
        assert!(parse_resolved("no pipe here", 0).is_none());
    }

    #[test]
    fn an_unknown_height_reads_as_zero() {
        let stream = parse_resolved("https://example.com/v.mp4|NA", 0).unwrap();
        assert_eq!(stream.height, 0);
    }

    #[test]
    fn the_selector_prefers_a_universally_decodable_codec() {
        let relaxed = format_selector(720, false);
        let avc1 = relaxed.find("vcodec^=avc1").expect("h264 must be offered");
        let vp9 = relaxed.find("vcodec^=vp9").expect("vp9 must be offered");
        assert!(avc1 < vp9, "h264 must be asked for first");
        assert!(relaxed.contains("height<=720"));
        assert_eq!(
            relaxed.matches("protocol^=http").count(),
            relaxed.matches('/').count() + 1,
            "every clause must rule out the HLS variants of the same video"
        );

        let strict = format_selector(480, true);
        assert!(strict.contains("vcodec^=avc1"));
        assert!(strict.contains("protocol^=http"));
        assert!(!strict.contains("vp9"));
        assert!(!strict.contains("[ext=mp4]"));
    }

    #[test]
    fn finds_the_expiry_parameter_anywhere_in_the_query() {
        assert_eq!(expiry_of("https://x/y?a=1&expire=42&b=2"), Some(42));
        assert_eq!(expiry_of("https://x/y?expires=42"), None);
        assert_eq!(expiry_of("https://x/y"), None);
    }
}
