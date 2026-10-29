//! Reads a clip's stretch of the song and writes the finished MP4 or PNG, with
//! ffmpeg doing the decoding and encoding. Mirrors
//! `Features/LyricShare/LyricShareAudio.swift` and `LyricShareExporter.swift`.

use super::render::Renderer;
use super::Scene;
use flaccy_shared::lyric_share::{gain, Format, Window, FPS};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};

/// A clip's stretch of the song, faded in and out: interleaved stereo floats,
/// and a mono mix of the same for the visualizer.
pub struct ClipAudio {
    pub interleaved: Vec<f32>,
    pub mono: Vec<f32>,
    pub sample_rate: u32,
}

#[cfg(test)]
impl ClipAudio {
    pub fn frame_count(&self) -> usize {
        self.interleaved.len() / 2
    }

    pub fn duration(&self) -> f64 {
        self.frame_count() as f64 / self.sample_rate as f64
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum ExportError {
    MissingFfmpeg,
    Unreadable(String),
    OutOfRange,
    Cancelled,
    Encoder(String),
    Image(String),
}

/// AAC's own rates: the CD family stays at 44.1 kHz, everything else goes to
/// 48 kHz.
pub fn target_rate(source_rate: Option<u32>) -> u32 {
    match source_rate {
        Some(rate) if rate > 0 && rate % 44_100 == 0 => 44_100,
        _ => 48_000,
    }
}

/// Reads the window's stretch of `input` (a file path or the loopback URL of
/// a song on a server), mixes it to stereo at `rate` and applies the fades.
pub fn load_audio(input: &str, window: &Window, rate: u32) -> Result<ClipAudio, ExportError> {
    let ffmpeg = crate::downloads::resolve_tool("ffmpeg").ok_or(ExportError::MissingFfmpeg)?;
    let output = Command::new(ffmpeg)
        .args(["-v", "error", "-nostdin"])
        .args(["-ss", &format!("{:.3}", window.audio_start().max(0.0))])
        .args(["-t", &format!("{:.3}", window.duration)])
        .args(["-i", input])
        .args(["-vn", "-ac", "2", "-ar", &rate.to_string(), "-f", "f32le", "pipe:1"])
        .stdin(Stdio::null())
        .stderr(Stdio::piped())
        .stdout(Stdio::piped())
        .output()
        .map_err(|error| ExportError::Unreadable(error.to_string()))?;
    if !output.status.success() {
        let reason = String::from_utf8_lossy(&output.stderr).lines().last().unwrap_or("").trim().to_string();
        return Err(ExportError::Unreadable(if reason.is_empty() { "ffmpeg failed".into() } else { reason }));
    }
    let samples: Vec<f32> = output
        .stdout
        .chunks_exact(4)
        .map(|bytes| f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
        .collect();
    let frames = samples.len() / 2;
    if frames == 0 {
        return Err(ExportError::OutOfRange);
    }
    let duration = frames as f64 / rate as f64;
    let mut interleaved = Vec::with_capacity(frames * 2);
    let mut mono = Vec::with_capacity(frames);
    for index in 0..frames {
        let level = gain(index as f64 / rate as f64, duration) as f32;
        let (left, right) = (samples[index * 2], samples[index * 2 + 1]);
        interleaved.push(left * level);
        interleaved.push(right * level);
        mono.push((left + right) * 0.5);
    }
    Ok(ClipAudio {
        interleaved,
        mono,
        sample_rate: rate,
    })
}

/// The clip as a WAV the preview player can loop.
pub fn write_wav(audio: &ClipAudio, path: &Path) -> std::io::Result<()> {
    let data_bytes = (audio.interleaved.len() * 4) as u32;
    let mut out = Vec::with_capacity(44 + data_bytes as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_bytes).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&3u16.to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&audio.sample_rate.to_le_bytes());
    out.extend_from_slice(&(audio.sample_rate * 8).to_le_bytes());
    out.extend_from_slice(&8u16.to_le_bytes());
    out.extend_from_slice(&32u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_bytes.to_le_bytes());
    for sample in &audio.interleaved {
        out.extend_from_slice(&sample.to_le_bytes());
    }
    std::fs::write(path, out)
}

/// The best H.264 encoder this ffmpeg has, from the ones that need no setup.
fn video_encoder(ffmpeg: &Path) -> &'static str {
    let listed = Command::new(ffmpeg)
        .args(["-hide_banner", "-encoders"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map(|output| String::from_utf8_lossy(&output.stdout).into_owned())
        .unwrap_or_default();
    let has = |name: &str| listed.lines().any(|line| line.split_whitespace().nth(1) == Some(name));
    ["libx264", "libopenh264", "h264_nvenc", "mpeg4"]
        .into_iter()
        .find(|name| has(name))
        .unwrap_or("mpeg4")
}

fn encoder_arguments(encoder: &str, format: Format) -> Vec<String> {
    let bitrate = format!("{}k", format.pixel_width() * format.pixel_height() * 5 / 1000);
    let list: Vec<&str> = match encoder {
        "libx264" => vec!["-c:v", "libx264", "-preset", "medium", "-crf", "18", "-profile:v", "high"],
        "libopenh264" => vec!["-c:v", "libopenh264", "-b:v", &bitrate],
        "h264_nvenc" => vec!["-c:v", "h264_nvenc", "-preset", "p5", "-b:v", &bitrate],
        _ => vec!["-c:v", "mpeg4", "-q:v", "2"],
    };
    list.into_iter().map(str::to_string).collect()
}

/// Encodes the scene over its audio into an H.264 + AAC MP4 at `out`, frame
/// by frame on the calling thread. `cancel` stops it between frames.
pub fn export_video(
    scene: Scene,
    audio: &ClipAudio,
    out: &Path,
    cancel: &AtomicBool,
    progress: impl Fn(f64),
) -> Result<(), ExportError> {
    let ffmpeg = crate::downloads::resolve_tool("ffmpeg").ok_or(ExportError::MissingFfmpeg)?;
    let encoder = video_encoder(&ffmpeg);
    let format = scene.style.format;
    let frames = scene.frame_count();
    let mut renderer = Renderer::new(scene, 1.0);
    let (width, height) = (renderer.width, renderer.height);
    let raw_audio = scratch_path(out, "pcm");
    let mut bytes = Vec::with_capacity(audio.interleaved.len() * 4);
    for sample in &audio.interleaved {
        bytes.extend_from_slice(&sample.to_le_bytes());
    }
    std::fs::write(&raw_audio, bytes).map_err(|error| ExportError::Encoder(error.to_string()))?;
    let _ = std::fs::remove_file(out);
    let mut child = Command::new(&ffmpeg)
        .args(["-y", "-v", "error"])
        .args(["-f", "rawvideo", "-pix_fmt", "bgra", "-s", &format!("{width}x{height}")])
        .args(["-r", &FPS.to_string(), "-i", "pipe:0"])
        .args(["-f", "f32le", "-ar", &audio.sample_rate.to_string(), "-ac", "2", "-i"])
        .arg(&raw_audio)
        .args(["-map", "0:v", "-map", "1:a"])
        .args(encoder_arguments(encoder, format))
        .args(["-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p"])
        .args(["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"])
        .args(["-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart"])
        .args(["-t", &format!("{:.3}", frames as f64 / FPS as f64)])
        .arg(out)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| ExportError::Encoder(error.to_string()))?;
    let mut stdin = child.stdin.take().expect("piped");
    let mut stderr = child.stderr.take().expect("piped");
    let errors = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = stderr.read_to_string(&mut text);
        text
    });
    let mut failure = None;
    for frame in 0..frames {
        if cancel.load(Ordering::Relaxed) {
            failure = Some(ExportError::Cancelled);
            break;
        }
        let Some(surface) = renderer.image(Some(frame)) else {
            failure = Some(ExportError::Encoder("frame".into()));
            break;
        };
        let written = write_surface(surface, width, height, &mut stdin);
        if let Err(error) = written {
            failure = Some(ExportError::Encoder(error.to_string()));
            break;
        }
        progress((frame + 1) as f64 / frames as f64);
    }
    drop(stdin);
    if failure.is_some() {
        let _ = child.kill();
    }
    let status = child.wait();
    let errors = errors.join().unwrap_or_default();
    let _ = std::fs::remove_file(&raw_audio);
    if let Some(failure) = failure {
        let _ = std::fs::remove_file(out);
        return Err(failure);
    }
    match status {
        Ok(status) if status.success() => Ok(()),
        _ => {
            let _ = std::fs::remove_file(out);
            let reason = errors.lines().last().unwrap_or("ffmpeg failed").trim().to_string();
            Err(ExportError::Encoder(reason))
        }
    }
}

fn write_surface(
    mut surface: cairo::ImageSurface,
    width: i32,
    height: i32,
    sink: &mut impl Write,
) -> std::io::Result<()> {
    let stride = surface.stride() as usize;
    let row = width as usize * 4;
    let data = surface
        .data()
        .map_err(|error| std::io::Error::other(error.to_string()))?;
    if stride == row {
        return sink.write_all(&data[..row * height as usize]);
    }
    for y in 0..height as usize {
        sink.write_all(&data[y * stride..y * stride + row])?;
    }
    Ok(())
}

/// Writes the still card as a PNG.
pub fn export_image(scene: Scene, out: &Path) -> Result<(), ExportError> {
    let mut renderer = Renderer::new(scene, 1.0);
    let surface = renderer
        .image(None)
        .ok_or_else(|| ExportError::Image("render".into()))?;
    let mut file = std::fs::File::create(out).map_err(|error| ExportError::Image(error.to_string()))?;
    surface
        .write_to_png(&mut file)
        .map_err(|error| ExportError::Image(error.to_string()))
}

fn scratch_path(out: &Path, extension: &str) -> PathBuf {
    let mut path = out.to_path_buf();
    path.set_extension(format!("{}.{extension}", std::process::id()));
    path
}
