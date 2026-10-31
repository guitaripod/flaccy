use super::Candidate;
use crate::downloads::{friendly_error, resolve_tool};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const RESOLVE_TIMEOUT_SECS: &str = "20";

/// Google's stream URLs carry their own expiry. Renewing a little early keeps
/// a long album from stalling on a URL that dies mid-song.
const EXPIRY_MARGIN_SECONDS: i64 = 300;

/// Used when the URL carries no expiry we can read, which is the case for
/// non-YouTube extractors.
const ASSUMED_LIFETIME_SECONDS: i64 = 1800;

/// How long a freshly issued URL is given to start answering. YouTube's TV
/// client hands out URLs that refuse every request for their first three
/// seconds or so; opened at once, the pipeline fails on a 403.
const WARMUP_LIMIT: Duration = Duration::from_secs(12);

const WARMUP_POLL: Duration = Duration::from_millis(400);

#[derive(Clone)]
pub struct Stream {
    pub url: String,
    pub expires_at: i64,
    pub height: i32,
    pub codec: Option<Codec>,
}

impl Stream {
    pub fn usable_at(&self, now: i64) -> bool {
        now + EXPIRY_MARGIN_SECONDS < self.expires_at
    }
}

/// The video codecs YouTube offers progressive streams in.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub enum Codec {
    Av1,
    Vp9,
    H264,
}

impl Codec {
    const ALL: [Codec; 3] = [Codec::Av1, Codec::Vp9, Codec::H264];

    fn caps(self) -> &'static str {
        match self {
            Codec::Av1 => "video/x-av1",
            Codec::Vp9 => "video/x-vp9",
            Codec::H264 => "video/x-h264",
        }
    }

    /// The prefix yt-dlp's `vcodec` field starts with for this codec.
    fn vcodec(self) -> &'static str {
        match self {
            Codec::Av1 => "av01",
            Codec::Vp9 => "vp9",
            Codec::H264 => "avc1",
        }
    }

    fn from_vcodec(value: &str) -> Option<Codec> {
        let value = value.to_ascii_lowercase();
        Codec::ALL.into_iter().find(|codec| {
            value.starts_with(codec.vcodec()) || (*codec == Codec::Vp9 && value.starts_with("vp09"))
        })
    }

    pub fn label(self) -> &'static str {
        match self {
            Codec::Av1 => "AV1",
            Codec::Vp9 => "VP9",
            Codec::H264 => "H.264",
        }
    }
}

/// A codec this machine can decode, and whether a GPU does the work.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Decodable {
    pub codec: Codec,
    pub hardware: bool,
}

/// Asks the GStreamer registry which of YouTube's codecs playbin would find a
/// decoder for, and which of those decoders are hardware. Only decoders
/// ranked high enough for playbin to plug them count.
pub fn decodable_codecs() -> Vec<Decodable> {
    let factories = gst::ElementFactory::factories_with_type(
        gst::ElementFactoryType::DECODER | gst::ElementFactoryType::MEDIA_VIDEO,
        gst::Rank::MARGINAL,
    );
    Codec::ALL
        .into_iter()
        .filter_map(|codec| {
            let caps = gst::Caps::builder(codec.caps()).build();
            let decoders: Vec<&gst::ElementFactory> = factories
                .iter()
                .filter(|factory| factory.can_sink_any_caps(&caps))
                .collect();
            if decoders.is_empty() {
                return None;
            }
            let hardware = decoders.iter().any(|factory| {
                factory
                    .metadata(gst::ELEMENT_METADATA_KLASS)
                    .is_some_and(|klass| klass.contains("Hardware"))
            });
            Some(Decodable { codec, hardware })
        })
        .collect()
}

/// Orders the decodable codecs by what they cost here. A GPU decodes any of
/// them for free, so there the smallest stream wins: AV1 carries the same
/// picture in about a third of H.264's bytes. In software H.264 is by far the
/// cheapest to decode, AV1 the dearest.
pub fn preference(decodable: &[Decodable]) -> Vec<Codec> {
    let rank = |entry: &Decodable| -> usize {
        match (entry.hardware, entry.codec) {
            (true, Codec::Av1) => 0,
            (true, Codec::Vp9) => 1,
            (true, Codec::H264) => 2,
            (false, Codec::H264) => 3,
            (false, Codec::Vp9) => 4,
            (false, Codec::Av1) => 5,
        }
    };
    let mut ordered = decodable.to_vec();
    ordered.sort_by_key(rank);
    ordered.into_iter().map(|entry| entry.codec).collect()
}

/// Resolves a playable video-only stream, and with it the video's own title,
/// channel and runtime. Audio is deliberately never requested: the sound comes
/// from the lossless file on disk, and a video-only stream is both smaller and
/// free of a second audio clock to fight with.
///
/// `codecs` is the order codecs are preferred in at equal height; `strict`
/// keeps only the most certainly decodable one, the retry after a pipeline
/// reports a missing plug-in.
pub fn resolve(
    video_id: &str,
    max_height: i32,
    codecs: &[Codec],
    strict: bool,
    now: i64,
) -> Result<(Stream, Candidate), String> {
    let Some(yt_dlp) = resolve_tool("yt-dlp") else {
        return Err(super::YT_DLP_MISSING.to_string());
    };
    let output = Command::new(yt_dlp)
        .args(["--no-warnings", "--ignore-config", "--no-playlist"])
        .args(["--socket-timeout", RESOLVE_TIMEOUT_SECS])
        .args([
            "--print",
            "%(.{id,title,channel,uploader,duration,view_count,formats})j",
        ])
        .arg(super::search::watch_url(video_id))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|err| format!("could not start yt-dlp: {err}"))?;
    if !output.status.success() {
        return Err(friendly_error(&String::from_utf8_lossy(&output.stderr)));
    }
    let printed = String::from_utf8_lossy(&output.stdout);
    parse_resolved(&printed, max_height, codecs, strict, now)
        .ok_or_else(|| "no format of this video plays here".to_string())
}

/// The codecs a choice may use, best first. With nothing known about the
/// decoders, H.264 then VP9 — what every GStreamer install of the last decade
/// plays.
fn allowed_codecs(codecs: &[Codec], strict: bool) -> Vec<Codec> {
    let known = if codecs.is_empty() {
        vec![Codec::H264, Codec::Vp9]
    } else {
        codecs.to_vec()
    };
    if strict {
        let safest = if known.contains(&Codec::H264) {
            Codec::H264
        } else {
            known[0]
        };
        return vec![safest];
    }
    known
}

/// Picks the format to stream from yt-dlp's list: plain HTTP only — the same
/// video is also offered as HLS, whose segments need a transport-stream
/// demuxer many installs lack, and one progressive URL is what the seek-driven
/// sync wants — no taller than the ceiling, in a codec this machine decodes.
/// The tallest wins; at equal height a video-only stream beats a muxed one
/// (its audio would only be thrown away), then the cheaper codec here, then
/// the higher bitrate.
pub fn choose_format<'a>(
    formats: &'a [serde_json::Value],
    max_height: i32,
    codecs: &[Codec],
    strict: bool,
) -> Option<&'a serde_json::Value> {
    let allowed = allowed_codecs(codecs, strict);
    formats
        .iter()
        .filter_map(|format| {
            let protocol = format.get("protocol")?.as_str()?;
            if protocol != "https" && protocol != "http" {
                return None;
            }
            format
                .get("url")?
                .as_str()
                .filter(|url| url.starts_with("http"))?;
            let height = format.get("height")?.as_i64()?;
            if height <= 0 || height > max_height as i64 {
                return None;
            }
            let codec = Codec::from_vcodec(format.get("vcodec")?.as_str()?)?;
            let rank = allowed.iter().position(|allowed| *allowed == codec)?;
            let video_only = format.get("acodec").and_then(|v| v.as_str()) == Some("none");
            let bitrate = format.get("tbr").and_then(|v| v.as_f64()).unwrap_or(0.0);
            Some((format, height, video_only, rank, bitrate))
        })
        .max_by(|a, b| {
            a.1.cmp(&b.1)
                .then(a.2.cmp(&b.2))
                .then(b.3.cmp(&a.3))
                .then(a.4.total_cmp(&b.4))
        })
        .map(|(format, ..)| format)
}

/// Reads yt-dlp's printed JSON and chooses the stream. `None` when no format
/// fits — too tall, HLS only, or in codecs nothing here decodes.
pub fn parse_resolved(
    printed: &str,
    max_height: i32,
    codecs: &[Codec],
    strict: bool,
    now: i64,
) -> Option<(Stream, Candidate)> {
    let line = printed
        .lines()
        .map(str::trim)
        .find(|line| line.starts_with('{'))?;
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    let formats = value.get("formats")?.as_array()?;
    let format = choose_format(formats, max_height, codecs, strict)?;
    let url = format.get("url")?.as_str()?;
    let text = |key: &str| {
        value
            .get(key)
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string()
    };
    let channel = Some(text("channel"))
        .filter(|channel| !channel.is_empty())
        .unwrap_or_else(|| text("uploader"));
    let stream = Stream {
        url: url.to_string(),
        expires_at: expiry_of(url).unwrap_or(now + ASSUMED_LIFETIME_SECONDS),
        height: format.get("height").and_then(|v| v.as_i64()).unwrap_or(0) as i32,
        codec: format
            .get("vcodec")
            .and_then(|v| v.as_str())
            .and_then(Codec::from_vcodec),
    };
    let candidate = Candidate {
        id: text("id"),
        title: text("title"),
        channel,
        duration: value
            .get("duration")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0),
        view_count: value.get("view_count").and_then(|v| v.as_u64()),
        live_now: false,
    };
    Some((stream, candidate))
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

/// Waits until a freshly issued URL answers, so the pipeline never opens it
/// while YouTube is still refusing it. Returns false when it never did.
pub fn await_ready(url: &str) -> bool {
    let started = Instant::now();
    loop {
        let status = ureq::get(url)
            .set("Range", "bytes=0-0")
            .timeout(Duration::from_secs(8))
            .call()
            .map(|response| response.status())
            .or_else(|err| match err {
                ureq::Error::Status(code, _) => Ok(code),
                ureq::Error::Transport(_) => Err(()),
            });
        match status {
            Ok(200..=299) => return true,
            Ok(403) if started.elapsed() < WARMUP_LIMIT => std::thread::sleep(WARMUP_POLL),
            Ok(_) | Err(()) => return false,
        }
    }
}

/// Downloads the video's soundtrack so it can be matched against the library
/// file. The smallest audio format is plenty: the aligner listens at 11 kHz
/// for note onsets, not for fidelity.
pub fn download_audio(video_id: &str, into: &Path) -> Option<PathBuf> {
    let yt_dlp = resolve_tool("yt-dlp")?;
    std::fs::create_dir_all(into).ok()?;
    let template = into.join(format!("{video_id}.%(ext)s"));
    let status = Command::new(yt_dlp)
        .args([
            "--no-warnings",
            "--ignore-config",
            "--no-playlist",
            "--quiet",
        ])
        .args(["--socket-timeout", RESOLVE_TIMEOUT_SECS])
        .args(["-f", "wa[abr>40]/wa/ba/b"])
        .arg("-o")
        .arg(&template)
        .arg(super::search::watch_url(video_id))
        .stdin(Stdio::null())
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
                && path.extension().is_some_and(|ext| ext != "part")
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn format(
        id: &str,
        protocol: &str,
        height: i64,
        vcodec: &str,
        acodec: &str,
        tbr: f64,
    ) -> serde_json::Value {
        serde_json::json!({
            "format_id": id,
            "protocol": protocol,
            "url": format!("https://rr2---sn-x.googlevideo.com/videoplayback?expire=1787021467&itag={id}"),
            "height": height,
            "vcodec": vcodec,
            "acodec": acodec,
            "tbr": tbr
        })
    }

    fn listing() -> Vec<serde_json::Value> {
        vec![
            format("18", "https", 360, "avc1.42001E", "mp4a.40.2", 600.0),
            format("136", "https", 720, "avc1.4D401F", "none", 406.0),
            format("247", "https", 720, "vp9", "none", 325.0),
            format("398", "https", 720, "av01.0.05M.08", "none", 197.0),
            format("137", "https", 1080, "avc1.640028", "none", 1282.0),
            format("399", "https", 1080, "av01.0.08M.08", "none", 434.0),
            format("614", "m3u8_native", 1080, "vp09.00.40.08", "none", 2000.0),
            format("sb0", "mhtml", 90, "none", "none", 0.0),
        ]
    }

    fn chosen(
        formats: &[serde_json::Value],
        max: i32,
        codecs: &[Codec],
        strict: bool,
    ) -> Option<String> {
        choose_format(formats, max, codecs, strict)
            .and_then(|f| f.get("format_id"))
            .and_then(|id| id.as_str())
            .map(str::to_string)
    }

    #[test]
    fn the_tallest_stream_wins_then_the_cheapest_codec_here() {
        let formats = listing();
        let gpu = [Codec::Av1, Codec::H264, Codec::Vp9];
        assert_eq!(chosen(&formats, 1080, &gpu, false).as_deref(), Some("399"));
        assert_eq!(chosen(&formats, 720, &gpu, false).as_deref(), Some("398"));
        let software = [Codec::H264, Codec::Vp9, Codec::Av1];
        assert_eq!(
            chosen(&formats, 720, &software, false).as_deref(),
            Some("136")
        );
        assert_eq!(
            chosen(&formats, 480, &software, false).as_deref(),
            Some("18")
        );
    }

    #[test]
    fn a_taller_stream_in_a_dearer_codec_beats_a_shorter_cheap_one() {
        let formats = vec![
            format("397", "https", 480, "av01.0.04M.08", "none", 423.0),
            format("136", "https", 720, "avc1.4D401F", "none", 406.0),
        ];
        assert_eq!(
            chosen(&formats, 720, &[Codec::Av1, Codec::H264], false).as_deref(),
            Some("136")
        );
    }

    #[test]
    fn hls_and_undecodable_codecs_are_never_chosen() {
        let formats = listing();
        assert_eq!(
            chosen(&formats, 1080, &[Codec::Vp9], false).as_deref(),
            Some("247")
        );
        let hls_only = vec![format(
            "614",
            "m3u8_native",
            1080,
            "vp09.00.40.08",
            "none",
            2000.0,
        )];
        assert!(chosen(&hls_only, 1080, &[Codec::Vp9], false).is_none());
    }

    #[test]
    fn the_strict_retry_keeps_only_h264_when_it_decodes() {
        let formats = listing();
        assert_eq!(
            chosen(&formats, 1080, &[Codec::Av1, Codec::H264], true).as_deref(),
            Some("137")
        );
        assert_eq!(
            chosen(&formats, 1080, &[Codec::Av1], true).as_deref(),
            Some("399")
        );
        assert_eq!(chosen(&formats, 1080, &[], false).as_deref(), Some("137"));
    }

    #[test]
    fn reads_the_printed_video_and_the_stream_chosen_for_it() {
        let printed = serde_json::json!({
            "id": "a5uQMwRMHcs",
            "title": "Daft Punk - Instant Crush (Official Video)",
            "channel": null,
            "uploader": "Daft Punk",
            "duration": 340,
            "view_count": 909432074u64,
            "formats": listing()
        })
        .to_string();
        let (stream, video) = parse_resolved(
            &printed,
            1080,
            &[Codec::Av1, Codec::H264],
            false,
            1_786_999_000,
        )
        .unwrap();
        assert_eq!(stream.height, 1080);
        assert_eq!(stream.codec, Some(Codec::Av1));
        assert_eq!(stream.expires_at, 1_787_021_467);
        assert!(stream.usable_at(1_786_999_000));
        assert!(!stream.usable_at(1_787_021_400));
        assert!(stream.url.contains("itag=399"));
        assert_eq!(video.id, "a5uQMwRMHcs");
        assert_eq!(video.channel, "Daft Punk");
        assert_eq!(video.duration, 340.0);
        assert_eq!(video.view_count, Some(909_432_074));
    }

    #[test]
    fn rejects_output_that_holds_no_playable_stream() {
        assert!(parse_resolved("", 720, &[], false, 0).is_none());
        assert!(parse_resolved("WARNING: something", 720, &[], false, 0).is_none());
        assert!(parse_resolved(r#"{"id": "x", "formats": []}"#, 720, &[], false, 0).is_none());
    }

    #[test]
    fn a_url_without_an_expiry_gets_an_assumed_lifetime() {
        let printed = serde_json::json!({
            "id": "x",
            "formats": [{"protocol": "https", "url": "https://example.com/video.mp4", "height": 720, "vcodec": "vp09.00.40.08", "acodec": "none"}]
        })
        .to_string();
        let (stream, _) = parse_resolved(&printed, 1080, &[Codec::Vp9], false, 1_000).unwrap();
        assert_eq!(stream.expires_at, 1_000 + ASSUMED_LIFETIME_SECONDS);
        assert_eq!(stream.codec, Some(Codec::Vp9));
    }

    #[test]
    fn a_gpu_decoder_puts_the_smallest_stream_first() {
        let nvidia = [
            Decodable {
                codec: Codec::H264,
                hardware: true,
            },
            Decodable {
                codec: Codec::Vp9,
                hardware: false,
            },
            Decodable {
                codec: Codec::Av1,
                hardware: true,
            },
        ];
        assert_eq!(
            preference(&nvidia),
            vec![Codec::Av1, Codec::H264, Codec::Vp9]
        );
        let software = [
            Decodable {
                codec: Codec::Av1,
                hardware: false,
            },
            Decodable {
                codec: Codec::Vp9,
                hardware: false,
            },
            Decodable {
                codec: Codec::H264,
                hardware: false,
            },
        ];
        assert_eq!(
            preference(&software),
            vec![Codec::H264, Codec::Vp9, Codec::Av1]
        );
    }

    #[test]
    fn finds_the_expiry_parameter_anywhere_in_the_query() {
        assert_eq!(expiry_of("https://x/y?a=1&expire=42&b=2"), Some(42));
        assert_eq!(expiry_of("https://x/y?expires=42"), None);
        assert_eq!(expiry_of("https://x/y"), None);
    }

    #[test]
    fn reads_codec_names_the_way_yt_dlp_writes_them() {
        assert_eq!(Codec::from_vcodec("avc1.640028"), Some(Codec::H264));
        assert_eq!(Codec::from_vcodec("vp9"), Some(Codec::Vp9));
        assert_eq!(Codec::from_vcodec("vp09.00.51.08"), Some(Codec::Vp9));
        assert_eq!(Codec::from_vcodec("av01.0.08M.08"), Some(Codec::Av1));
        assert_eq!(Codec::from_vcodec("none"), None);
    }
}
