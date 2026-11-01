//! Getting one video file onto the disk without ever leaving a file that
//! looks finished and is not: ranged chunks into `<name>.part`, resumed from
//! whatever bytes are already there, then checked with ffprobe before the
//! rename that makes it the cache's.

use crate::downloads::resolve_tool;
use flaccy_shared::precache::Failure;
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// googlevideo throttles a client that asks for a whole file and serves one
/// that asks in pieces at full speed, which is how yt-dlp downloads too.
pub const CHUNK_BYTES: u64 = 10 * 1024 * 1024;

/// Bytes a second the lane may take, so a fill leaves the connection to the
/// rest of the house.
pub const RATE_CAP: u64 = 8 * 1024 * 1024;

const CHUNK_TIMEOUT: Duration = Duration::from_secs(60);

const READ_BUFFER: usize = 64 * 1024;

/// How a download ended without producing a file.
#[derive(Debug, PartialEq)]
pub enum Stop {
    /// The plan changed; the partial file is kept for the next try.
    Preempted,
    /// The file will not fit; the partial file is gone.
    NoRoom { need: u64 },
    /// The URL no longer works and a fresh one might.
    Refused,
    Failed(Failure, String),
}

/// What the server said a ranged answer covers: first byte, last byte, whole
/// size.
pub fn parse_content_range(header: &str) -> Option<(u64, u64, u64)> {
    let range = header.trim().strip_prefix("bytes ")?;
    let (span, total) = range.split_once('/')?;
    let (first, last) = span.split_once('-')?;
    Some((first.parse().ok()?, last.parse().ok()?, total.parse().ok()?))
}

/// The container a googlevideo URL names in its `mime` parameter.
pub fn extension_of(url: &str) -> &'static str {
    let mime = url
        .split_once('?')
        .map(|(_, query)| query)
        .unwrap_or_default()
        .split('&')
        .filter_map(|pair| pair.split_once('='))
        .find(|(key, _)| *key == "mime")
        .map(|(_, value)| value.replace("%2F", "/").replace("%2f", "/"))
        .unwrap_or_default();
    if mime.contains("webm") {
        "webm"
    } else if mime.contains("matroska") {
        "mkv"
    } else {
        "mp4"
    }
}

fn status_failure(code: u16) -> Stop {
    match code {
        403 | 410 => Stop::Refused,
        404 => Stop::Failed(Failure::NotFound, "YouTube no longer serves this video".into()),
        429 => Stop::Failed(Failure::Throttled, "YouTube asked for fewer requests".into()),
        500..=599 => Stop::Failed(Failure::Transient, format!("YouTube answered {code}")),
        _ => Stop::Failed(Failure::Blocked, format!("YouTube answered {code}")),
    }
}

fn io_failure(err: std::io::Error, doing: &str) -> Stop {
    Stop::Failed(Failure::Transient, format!("could not {doing}: {err}"))
}

/// Downloads `url` into `part`, continuing from the bytes already there.
/// `reserve` is asked once, with the whole size, before more than the first
/// chunk is kept: `false` abandons the download for want of room.
/// `progress` hears the bytes held and the total after each chunk.
pub fn download(
    url: &str,
    part: &Path,
    chunk: u64,
    rate: u64,
    reserve: &mut dyn FnMut(u64) -> bool,
    progress: &mut dyn FnMut(u64, u64),
    preempted: &dyn Fn() -> bool,
) -> Result<u64, Stop> {
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(part)
        .map_err(|err| io_failure(err, "open the video's partial file"))?;
    let mut have = file
        .metadata()
        .map_err(|err| io_failure(err, "read the video's partial file"))?
        .len();
    let mut total: Option<u64> = None;
    let mut restarted = false;
    loop {
        if preempted() {
            return Err(Stop::Preempted);
        }
        if total.is_some_and(|total| have >= total) {
            return Ok(have);
        }
        let started = Instant::now();
        let range = format!("bytes={have}-{}", have + chunk - 1);
        let response = match ureq::get(url).set("Range", &range).timeout(CHUNK_TIMEOUT).call() {
            Ok(response) => response,
            Err(ureq::Error::Status(416, _)) if have > 0 && !restarted => {
                restarted = true;
                file.set_len(0).map_err(|err| io_failure(err, "restart the download"))?;
                have = 0;
                total = None;
                continue;
            }
            Err(ureq::Error::Status(code, _)) => return Err(status_failure(code)),
            Err(ureq::Error::Transport(err)) => {
                return Err(Stop::Failed(Failure::Transient, format!("the connection failed: {err}")))
            }
        };
        let (expected, whole) = if response.status() == 206 {
            let Some((first, last, whole)) = response
                .header("Content-Range")
                .and_then(parse_content_range)
                .filter(|(first, last, whole)| *first == have && last >= first && last < whole)
            else {
                return Err(Stop::Failed(
                    Failure::Transient,
                    "YouTube answered with a range that does not match the request".into(),
                ));
            };
            (last - first + 1, whole)
        } else {
            let Some(length) = response
                .header("Content-Length")
                .and_then(|value| value.parse::<u64>().ok())
            else {
                return Err(Stop::Failed(Failure::Transient, "YouTube did not say how big the video is".into()));
            };
            if have > 0 {
                file.set_len(0).map_err(|err| io_failure(err, "restart the download"))?;
                have = 0;
            }
            (length, length)
        };
        if total.is_none() {
            total = Some(whole);
            if !reserve(whole) {
                drop(file);
                let _ = std::fs::remove_file(part);
                return Err(Stop::NoRoom { need: whole });
            }
        }
        let written = copy_chunk(response.into_reader(), &mut file).map_err(|err| {
            let _ = file.set_len(have);
            io_failure(err, "write the video")
        })?;
        if written != expected {
            let _ = file.set_len(have);
            return Err(Stop::Failed(
                Failure::Transient,
                "the stream ended before the chunk did".into(),
            ));
        }
        have += written;
        progress(have, whole);
        let spent = started.elapsed();
        let owed = Duration::from_secs_f64(written as f64 / rate.max(1) as f64);
        if spent < owed {
            std::thread::sleep(owed - spent);
        }
    }
}

fn copy_chunk(mut from: impl Read, to: &mut impl Write) -> std::io::Result<u64> {
    let mut buffer = vec![0u8; READ_BUFFER];
    let mut written = 0u64;
    loop {
        let read = from.read(&mut buffer)?;
        if read == 0 {
            to.flush()?;
            return Ok(written);
        }
        to.write_all(&buffer[..read])?;
        written += read as u64;
    }
}

/// What ffprobe saw in a finished download.
#[derive(Debug, PartialEq)]
pub struct Probed {
    pub duration: f64,
    pub height: i32,
    pub codec: String,
}

/// Reads the file the way a player would. `None` when ffprobe is not
/// installed, so a machine without it still prepares videos on the strength
/// of their size.
pub fn probe(path: &Path) -> Option<Result<Probed, String>> {
    let ffprobe = resolve_tool("ffprobe")?;
    let output = Command::new(ffprobe)
        .args(["-v", "error", "-select_streams", "v:0", "-show_entries"])
        .arg("stream=codec_name,height:format=duration")
        .args(["-of", "json"])
        .arg(path)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output();
    Some(match output {
        Ok(output) if output.status.success() => parse_probe(&String::from_utf8_lossy(&output.stdout)),
        Ok(_) => Err("ffprobe could not read the file".to_string()),
        Err(err) => Err(format!("could not run ffprobe: {err}")),
    })
}

pub fn parse_probe(json: &str) -> Result<Probed, String> {
    let value: serde_json::Value =
        serde_json::from_str(json).map_err(|_| "ffprobe printed nothing readable".to_string())?;
    let stream = value
        .get("streams")
        .and_then(|streams| streams.get(0))
        .ok_or_else(|| "the file holds no video".to_string())?;
    let duration = value
        .get("format")
        .and_then(|format| format.get("duration"))
        .and_then(|duration| duration.as_str())
        .and_then(|duration| duration.parse::<f64>().ok())
        .ok_or_else(|| "the file has no length".to_string())?;
    Ok(Probed {
        duration,
        height: stream.get("height").and_then(|h| h.as_i64()).unwrap_or(0) as i32,
        codec: stream
            .get("codec_name")
            .and_then(|codec| codec.as_str())
            .unwrap_or_default()
            .to_string(),
    })
}

/// Whether a probed file is the video that was asked for: it runs as long as
/// the upload said, within a few seconds or three percent.
pub fn matches_length(probed: &Probed, expected: f64) -> bool {
    if expected <= 0.0 {
        return probed.duration > 1.0;
    }
    (probed.duration - expected).abs() <= (expected * 0.03).max(3.0)
}

#[cfg(test)]
mod tests {
    use super::super::test_server::{payload, scratch, serve, Mode};
    use super::*;
    use std::sync::atomic::Ordering;

    fn run(url: &str, part: &Path, reserve: bool, preempt_after: Option<usize>) -> Result<u64, Stop> {
        let chunks = std::cell::Cell::new(0usize);
        download(
            url,
            part,
            1000,
            u64::MAX,
            &mut |_| reserve,
            &mut |_, _| chunks.set(chunks.get() + 1),
            &|| preempt_after.is_some_and(|after| chunks.get() >= after),
        )
    }

    #[test]
    fn a_video_arrives_whole_in_chunks() {
        let body = payload(3500);
        let stub = serve(Mode::Serve, body.clone());
        let dir = scratch("whole");
        let part = dir.join("a.part");
        assert_eq!(run(&stub.url, &part, true, None), Ok(3500));
        assert_eq!(std::fs::read(&part).unwrap(), body);
        assert_eq!(stub.hits.load(Ordering::SeqCst), 4);
    }

    #[test]
    fn a_preempted_download_resumes_where_it_stopped() {
        let body = payload(3500);
        let stub = serve(Mode::Serve, body.clone());
        let dir = scratch("resume");
        let part = dir.join("a.part");
        assert_eq!(run(&stub.url, &part, true, Some(2)), Err(Stop::Preempted));
        assert_eq!(std::fs::metadata(&part).unwrap().len(), 2000);
        assert_eq!(run(&stub.url, &part, true, None), Ok(3500));
        assert_eq!(std::fs::read(&part).unwrap(), body);
    }

    #[test]
    fn a_server_that_ignores_ranges_is_read_from_the_start() {
        let body = payload(2500);
        let stub = serve(Mode::IgnoreRange, body.clone());
        let dir = scratch("ignore");
        let part = dir.join("a.part");
        std::fs::write(&part, &body[..700]).unwrap();
        assert_eq!(run(&stub.url, &part, true, None), Ok(2500));
        assert_eq!(std::fs::read(&part).unwrap(), body);
    }

    #[test]
    fn no_room_removes_the_partial_file_before_more_is_kept() {
        let stub = serve(Mode::Serve, payload(3500));
        let dir = scratch("room");
        let part = dir.join("a.part");
        assert_eq!(run(&stub.url, &part, false, None), Err(Stop::NoRoom { need: 3500 }));
        assert!(!part.exists());
    }

    #[test]
    fn a_stream_that_dies_mid_chunk_leaves_only_whole_chunks_behind() {
        let stub = serve(Mode::CutShort, payload(3500));
        let dir = scratch("short");
        let part = dir.join("a.part");
        let outcome = run(&stub.url, &part, true, None);
        assert!(matches!(outcome, Err(Stop::Failed(Failure::Transient, _))), "{outcome:?}");
        assert_eq!(std::fs::metadata(&part).unwrap().len(), 0);
    }

    #[test]
    fn refusals_and_throttles_are_told_apart() {
        let dir = scratch("status");
        for (code, expected) in [
            (403, Stop::Refused),
            (410, Stop::Refused),
            (429, Stop::Failed(Failure::Throttled, "YouTube asked for fewer requests".into())),
            (404, Stop::Failed(Failure::NotFound, "YouTube no longer serves this video".into())),
            (503, Stop::Failed(Failure::Transient, "YouTube answered 503".into())),
            (418, Stop::Failed(Failure::Blocked, "YouTube answered 418".into())),
        ] {
            let stub = serve(Mode::Refuse(code), payload(10));
            let part = dir.join(format!("{code}.part"));
            assert_eq!(run(&stub.url, &part, true, None), Err(expected), "{code}");
        }
    }

    #[test]
    fn a_fresh_url_after_a_refusal_finishes_the_same_file() {
        let body = payload(2200);
        let stub = serve(Mode::FailOnce(403), body.clone());
        let dir = scratch("renew");
        let part = dir.join("a.part");
        assert_eq!(run(&stub.url, &part, true, None), Err(Stop::Refused));
        assert_eq!(run(&stub.url, &part, true, None), Ok(2200));
        assert_eq!(std::fs::read(&part).unwrap(), body);
    }

    #[test]
    fn reads_the_range_a_server_answers_with() {
        assert_eq!(parse_content_range("bytes 0-99/1000"), Some((0, 99, 1000)));
        assert_eq!(parse_content_range("bytes */1000"), None);
        assert_eq!(parse_content_range("items 0-1/2"), None);
    }

    #[test]
    fn the_container_comes_from_the_urls_mime() {
        assert_eq!(extension_of("https://x/videoplayback?mime=video%2Fwebm&itag=1"), "webm");
        assert_eq!(extension_of("https://x/videoplayback?itag=1&mime=video%2Fmp4"), "mp4");
        assert_eq!(extension_of("https://x/videoplayback"), "mp4");
    }

    #[test]
    fn a_probe_reads_codec_height_and_length() {
        let json = r#"{"streams":[{"codec_name":"av1","height":720}],"format":{"duration":"255.120000"}}"#;
        assert_eq!(
            parse_probe(json),
            Ok(Probed { duration: 255.12, height: 720, codec: "av1".into() })
        );
        assert!(parse_probe(r#"{"streams":[],"format":{"duration":"3"}}"#).is_err());
        assert!(parse_probe("not json").is_err());
    }

    #[test]
    fn a_file_must_run_about_as_long_as_the_upload_said() {
        let probed = |duration| Probed { duration, height: 720, codec: "av1".into() };
        assert!(matches_length(&probed(255.0), 256.0));
        assert!(matches_length(&probed(100.0), 102.9));
        assert!(!matches_length(&probed(120.0), 256.0));
        assert!(matches_length(&probed(30.0), 0.0));
        assert!(!matches_length(&probed(0.4), 0.0));
    }

    #[test]
    fn a_real_file_is_probed_and_a_garbage_one_is_not() {
        let (Some(ffmpeg), Some(_)) = (resolve_tool("ffmpeg"), resolve_tool("ffprobe")) else {
            return;
        };
        let dir = scratch("probe");
        let video = dir.join("real.mp4");
        let made = Command::new(ffmpeg)
            .args(["-v", "error", "-f", "lavfi", "-i", "testsrc=duration=2:size=64x48:rate=10"])
            .args(["-c:v", "mpeg4", "-y"])
            .arg(&video)
            .status();
        if !made.is_ok_and(|status| status.success()) {
            return;
        }
        let probed = probe(&video).expect("ffprobe is installed").expect("the file reads");
        assert_eq!(probed.height, 48);
        assert!(matches_length(&probed, 2.0));
        let garbage = dir.join("garbage.mp4");
        std::fs::write(&garbage, payload(5000)).unwrap();
        assert!(probe(&garbage).expect("ffprobe is installed").is_err());
    }

    /// Downloads the video named by `FLACCY_REAL_VIDEO` from YouTube the way
    /// the lane does and checks it with ffprobe:
    /// `FLACCY_REAL_VIDEO=<id> cargo test --release -p flaccy --bin flaccy real_video -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn real_video_downloads_in_chunks_and_probes() {
        let Ok(id) = std::env::var("FLACCY_REAL_VIDEO") else {
            return;
        };
        let now = chrono::Utc::now().timestamp();
        let codecs = [
            crate::musicvideo::stream::Codec::Av1,
            crate::musicvideo::stream::Codec::Vp9,
            crate::musicvideo::stream::Codec::H264,
        ];
        let (stream, candidate) =
            crate::musicvideo::stream::resolve(&id, 720, &codecs, false, now).expect("resolves");
        assert!(crate::musicvideo::stream::await_ready(&stream.url));
        let dir = scratch("real");
        let part = dir.join(format!("{id}.720.{}.part", extension_of(&stream.url)));
        let started = Instant::now();
        let total = download(
            &stream.url,
            &part,
            CHUNK_BYTES,
            RATE_CAP,
            &mut |total| {
                println!("{} bytes in all", total);
                true
            },
            &mut |have, total| println!("{have}/{total}"),
            &|| false,
        )
        .expect("downloads");
        println!("{total} bytes in {:.1} s", started.elapsed().as_secs_f64());
        let probed = probe(&part).expect("ffprobe").expect("readable");
        println!("{probed:?} against {} s", candidate.duration);
        assert!(matches_length(&probed, candidate.duration));
    }
}
