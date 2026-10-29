//! Streaming a song re-encoded by ffmpeg when a client asks for another format
//! or a lower bit rate.

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use axum::body::Body;
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::Response;
use tokio::process::Command;
use tokio::sync::{Semaphore, SemaphorePermit};
use tokio_util::io::ReaderStream;

use crate::error::ApiError;

const DEFAULT_KBPS: u32 = 192;
const DEFAULT_OPUS_KBPS: u32 = 128;
const MINIMUM_KBPS: u32 = 32;
const MAXIMUM_KBPS: u32 = 512;
/// The most ffmpeg conversions that run at once.
pub const CONCURRENT_CONVERSIONS: usize = 3;
/// How long a conversion waits for a free slot before the request is answered 503.
pub const QUEUE_WAIT: Duration = Duration::from_secs(20);
/// What a request to convert audio is told by a server that has no ffmpeg.
pub const NO_FFMPEG_MESSAGE: &str =
    "Converting audio needs ffmpeg, which this server does not have; ask for the original file.";
const RETRY_AFTER_SECONDS: &str = "20";

static CONVERSION_SLOTS: Semaphore = Semaphore::const_new(CONCURRENT_CONVERSIONS);

/// A format a client may ask `stream` to convert to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Target {
    Mp3,
    Opus,
    Aac,
    Mp4,
}

impl Target {
    /// The target a `format` parameter names.
    pub fn parse(format: &str) -> Option<Target> {
        match format.to_ascii_lowercase().as_str() {
            "mp3" => Some(Target::Mp3),
            "opus" | "ogg" => Some(Target::Opus),
            "aac" | "adts" => Some(Target::Aac),
            "mp4" | "m4a" => Some(Target::Mp4),
            _ => None,
        }
    }

    /// The media type the converted stream is sent as.
    pub fn content_type(self) -> &'static str {
        match self {
            Target::Mp3 => "audio/mpeg",
            Target::Opus => "audio/ogg",
            Target::Aac => "audio/aac",
            Target::Mp4 => "audio/mp4",
        }
    }

    fn bitrate(self, requested: Option<i64>) -> u32 {
        let default = if self == Target::Opus { DEFAULT_OPUS_KBPS } else { DEFAULT_KBPS };
        requested
            .filter(|kbps| *kbps > 0)
            .map(|kbps| (kbps as u32).clamp(MINIMUM_KBPS, MAXIMUM_KBPS))
            .unwrap_or(default)
    }

    fn codec_arguments(self, kbps: u32) -> Vec<String> {
        let rate = format!("{kbps}k");
        let pieces: Vec<&str> = match self {
            Target::Mp3 => vec!["-c:a", "libmp3lame", "-b:a", &rate, "-f", "mp3"],
            Target::Opus => vec!["-c:a", "libopus", "-b:a", &rate, "-f", "ogg"],
            Target::Aac => vec!["-c:a", "aac", "-b:a", &rate, "-f", "adts"],
            Target::Mp4 => vec![
                "-c:a",
                "aac",
                "-b:a",
                &rate,
                "-movflags",
                "frag_keyframe+empty_moov+default_base_moof",
                "-f",
                "mp4",
            ],
        };
        pieces.into_iter().map(str::to_string).collect()
    }
}

/// A free conversion slot, or `None` when none became free within `wait`.
async fn slot_within(slots: &'static Semaphore, wait: Duration) -> Option<SemaphorePermit<'static>> {
    tokio::time::timeout(wait, slots.acquire()).await.ok()?.ok()
}

/// The 503 a request gets when every conversion slot stayed busy for [`QUEUE_WAIT`].
fn busy_response() -> Response {
    let mut response = Response::new(Body::from(format!(
        "The server is already converting {CONCURRENT_CONVERSIONS} songs and none finished in {} seconds. Try again shortly, or ask for format=raw to get the original file.",
        QUEUE_WAIT.as_secs()
    )));
    *response.status_mut() = StatusCode::SERVICE_UNAVAILABLE;
    response
        .headers_mut()
        .insert(header::RETRY_AFTER, HeaderValue::from_static(RETRY_AFTER_SECONDS));
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain; charset=utf-8"));
    response
}

/// Starts ffmpeg on `input` and streams its output as the response body. There
/// is no length and no range support: the stream is produced as it plays. At
/// most [`CONCURRENT_CONVERSIONS`] run at once; a request that finds them all
/// busy for [`QUEUE_WAIT`] is answered `503` with `Retry-After`.
pub async fn stream(
    program: &str,
    input: &Path,
    target: Target,
    max_bit_rate: Option<i64>,
    offset_seconds: Option<i64>,
    head_only: bool,
) -> Result<Response, ApiError> {
    let kbps = target.bitrate(max_bit_rate);
    let mut response = Response::new(Body::empty());
    *response.status_mut() = StatusCode::OK;
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static(target.content_type()));
    response
        .headers_mut()
        .insert(header::ACCEPT_RANGES, HeaderValue::from_static("none"));
    if head_only {
        return Ok(response);
    }

    let Some(slot) = slot_within(&CONVERSION_SLOTS, QUEUE_WAIT).await else {
        return Ok(busy_response());
    };
    let mut command = Command::new(program);
    command.args(["-nostdin", "-v", "error"]);
    if let Some(offset) = offset_seconds.filter(|offset| *offset > 0) {
        command.args(["-ss", &offset.to_string()]);
    }
    command
        .arg("-i")
        .arg(input)
        .args(["-map", "0:a:0", "-vn", "-map_metadata", "-1"])
        .args(target.codec_arguments(kbps))
        .arg("pipe:1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = command.spawn().map_err(|err| {
        if err.kind() == std::io::ErrorKind::NotFound {
            ApiError::generic(
                "Converting a song needs ffmpeg and it is not installed on the server. Install ffmpeg (for example `pacman -S ffmpeg` or `apt install ffmpeg`) and make sure it is on the PATH of flaccy-server, or ask for format=raw to get the original file",
            )
        } else {
            ApiError::generic(format!(
                "Could not start ffmpeg to convert the song: {err}. Check that ffmpeg is executable by the user running flaccy-server, or ask for format=raw to get the original file"
            ))
        }
    })?;
    let stdout = child.stdout.take().ok_or_else(|| {
        ApiError::generic("ffmpeg started without an output pipe. This is a bug in flaccy-server; ask for format=raw to get the original file meanwhile")
    })?;
    tokio::spawn(async move {
        let _slot = slot;
        let _ = child.wait().await;
    });
    *response.body_mut() = Body::from_stream(ReaderStream::new(stdout));
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_parse_and_bitrates_clamp() {
        assert_eq!(Target::parse("MP3"), Some(Target::Mp3));
        assert_eq!(Target::parse("m4a"), Some(Target::Mp4));
        assert_eq!(Target::parse("wma"), None);
        assert_eq!(Target::Mp3.bitrate(None), 192);
        assert_eq!(Target::Opus.bitrate(Some(0)), 128);
        assert_eq!(Target::Mp3.bitrate(Some(1)), 32);
        assert_eq!(Target::Mp3.bitrate(Some(9999)), 512);
        assert_eq!(Target::Aac.bitrate(Some(256)), 256);
    }

    #[tokio::test]
    async fn a_busy_server_hands_out_three_slots_and_the_fourth_request_gives_up() {
        static SLOTS: Semaphore = Semaphore::const_new(CONCURRENT_CONVERSIONS);
        let held: Vec<_> = take_all_slots(&SLOTS).await;
        assert_eq!(held.len(), CONCURRENT_CONVERSIONS);
        assert!(slot_within(&SLOTS, Duration::from_millis(80)).await.is_none());
        drop(held);
        assert!(slot_within(&SLOTS, Duration::from_millis(80)).await.is_some());
    }

    async fn take_all_slots(slots: &'static Semaphore) -> Vec<SemaphorePermit<'static>> {
        let mut held = Vec::new();
        for _ in 0..CONCURRENT_CONVERSIONS {
            held.push(slot_within(slots, Duration::from_millis(80)).await.unwrap());
        }
        held
    }

    #[test]
    fn the_busy_answer_is_a_503_that_says_when_to_retry() {
        let response = busy_response();
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(response.headers()[header::RETRY_AFTER], "20");
    }
}
