//! Streaming a song re-encoded by ffmpeg when a client asks for another format
//! or a lower bit rate.

use std::path::Path;
use std::process::Stdio;

use axum::body::Body;
use axum::http::{header, HeaderValue, StatusCode};
use axum::response::Response;
use tokio::process::Command;
use tokio_util::io::ReaderStream;

use crate::error::ApiError;

const DEFAULT_KBPS: u32 = 192;
const DEFAULT_OPUS_KBPS: u32 = 128;
const MINIMUM_KBPS: u32 = 32;
const MAXIMUM_KBPS: u32 = 512;

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

/// Starts ffmpeg on `input` and streams its output as the response body. There
/// is no length and no range support: the stream is produced as it plays.
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
}
