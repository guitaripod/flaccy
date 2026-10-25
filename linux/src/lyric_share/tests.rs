use super::export::{self, ClipAudio, ExportError};
use super::render::Renderer;
use super::{Cover, Scene};
use flaccy_shared::lyric_share::{
    analyze, default_selection, frame_count, window, Format, Palette, Style, Template, Theme, FPS,
};
use flaccy_shared::lyrics::{parse_lrc, Document};
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

const FIXTURE: &str = "\
[00:01.00]<00:01.00>Neon <00:01.40>rivers <00:01.90>running <00:02.60>through <00:03.00>the <00:03.20>night
[00:04.00]<00:04.00>We <00:04.30>were <00:04.60>the <00:04.80>signal <00:05.60>in <00:05.80>the <00:06.00>static<00:07.20>
[00:07.40]Hold on, hold on to the sound
[00:10.20]<00:10.20>Every <00:10.70>heartbeat <00:11.60>turning <00:12.30>up <00:12.70>the <00:13.00>volume<00:14.40>
[00:15.00](hold on)
";

fn document() -> Document {
    parse_lrc(FIXTURE)
}

/// Twenty seconds of a chord over a kick on every beat, faded like a clip.
fn tone(rate: u32, seconds: f64) -> ClipAudio {
    let frames = (rate as f64 * seconds) as usize;
    let mut interleaved = Vec::with_capacity(frames * 2);
    let mut mono = Vec::with_capacity(frames);
    for index in 0..frames {
        let time = index as f64 / rate as f64;
        let beat = time % 0.5;
        let kick = (-beat * 18.0).exp() * (2.0 * std::f64::consts::PI * 55.0 * beat).sin() * 0.6;
        let chord = ((2.0 * std::f64::consts::PI * 220.0 * time).sin()
            + (2.0 * std::f64::consts::PI * 277.2 * time).sin()
            + (2.0 * std::f64::consts::PI * 329.6 * time).sin())
            * 0.08;
        let sample = (kick + chord) as f32;
        interleaved.push(sample);
        interleaved.push(sample);
        mono.push(sample);
    }
    ClipAudio { interleaved, mono, sample_rate: rate }
}

fn cover() -> Cover {
    let side = 300u32;
    let mut rgba = Vec::with_capacity((side * side * 4) as usize);
    for y in 0..side {
        for x in 0..side {
            let t = (x + y) as f64 / (2 * side) as f64;
            let inside = ((x as f64 - 150.0).powi(2) + (y as f64 - 150.0).powi(2)).sqrt() < 60.0;
            let (r, g, b) = if inside {
                (255, 217, 77)
            } else {
                ((242.0 - 190.0 * t) as u8, (89.0 - 64.0 * t) as u8, (115.0 + 12.0 * t) as u8)
            };
            rgba.extend_from_slice(&[r, g, b, 255]);
        }
    }
    Cover::from_rgba(&rgba, side, side)
}

fn scene(style: Style) -> (Scene, ClipAudio) {
    let document = document();
    let selection = default_selection(&document, Some(1.2)).expect("lines");
    let window = window(selection, &document, 0.0, 20.0);
    let audio = tone(48_000, window.duration);
    let analysis = analyze(&audio.mono, 48_000.0, frame_count(&window), FPS);
    let cover = cover();
    let palette = Palette::make(style.theme, &cover.samples());
    let scene = Scene {
        document: Arc::new(document),
        selection,
        plain_lines: None,
        window,
        style,
        palette,
        title: "Parallax Hours".into(),
        artist: "The Midnight Signal".into(),
        cover: Some(Arc::new(cover)),
        analysis: Arc::new(analysis),
    };
    (scene, audio)
}

/// Where frames are written for a person to look at, when asked for.
fn shots() -> Option<PathBuf> {
    std::env::var_os("FLACCY_LYRIC_SHARE_SHOTS").map(PathBuf::from)
}

fn pixel(surface: &mut cairo::ImageSurface, x: i32, y: i32) -> [u8; 4] {
    let stride = surface.stride() as usize;
    let data = surface.data().expect("data");
    let at = y as usize * stride + x as usize * 4;
    [data[at], data[at + 1], data[at + 2], data[at + 3]]
}

#[test]
fn every_template_and_format_draws_its_frames() {
    let probes = [12usize, 75, 130, 200];
    for template in Template::ALL {
        for (format, theme) in [
            (Format::Story, Theme::Artwork),
            (Format::Square, Theme::Vivid),
            (Format::Wide, Theme::Dark),
            (Format::Portrait, Theme::Light),
        ] {
            let style = Style { template, format, theme, ..Style::default() };
            let (scene, _) = scene(style);
            let mut renderer = Renderer::new(scene, 0.5);
            assert_eq!(renderer.width, (format.pixel_width() as f64 * 0.5).round() as i32);
            for frame in probes.iter().copied().map(Some).chain([None]) {
                let mut surface = renderer.image(frame).expect("frame");
                let corner = pixel(&mut surface, 2, 2);
                assert_eq!(corner[3], 255, "the canvas is opaque");
                if let Some(directory) = shots() {
                    let name = match frame {
                        Some(frame) => format!("{}-{}-{frame}.png", template.key(), format.key()),
                        None => format!("{}-{}-still.png", template.key(), format.key()),
                    };
                    let _ = std::fs::create_dir_all(&directory);
                    let mut file = std::fs::File::create(directory.join(name)).expect("file");
                    surface.write_to_png(&mut file).expect("png");
                }
            }
        }
    }
}

#[test]
fn the_light_theme_paints_a_light_canvas_and_dark_ink() {
    let style = Style { theme: Theme::Light, template: Template::Poster, ..Style::default() };
    let (scene, _) = scene(style);
    let mut renderer = Renderer::new(scene, 0.25);
    let mut surface = renderer.image(None).expect("still");
    let corner = pixel(&mut surface, 4, 4);
    assert!(corner[0] > 200 && corner[1] > 200 && corner[2] > 200, "{corner:?}");
}

#[test]
fn a_clip_encodes_to_an_mp4_with_both_tracks() {
    if crate::downloads::resolve_tool("ffmpeg").is_none() {
        return;
    }
    let directory = std::env::temp_dir().join(format!("flaccy-lyric-share-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&directory);
    let (scene, audio) = scene(Style::default());
    let frames = scene.frame_count();
    let out = directory.join("clip.mp4");
    let progress = std::cell::Cell::new(0.0);
    export::export_video(scene.clone(), &audio, &out, &AtomicBool::new(false), |value| progress.set(value))
        .expect("export");
    assert!((progress.get() - 1.0).abs() < 1e-9);
    let probe = std::process::Command::new(crate::downloads::resolve_tool("ffprobe").unwrap_or("ffprobe".into()))
        .args(["-v", "error", "-show_entries", "stream=codec_type,width,height,duration", "-of", "compact"])
        .arg(&out)
        .output()
        .expect("ffprobe");
    let text = String::from_utf8_lossy(&probe.stdout);
    assert!(text.contains("codec_type=video|width=1080|height=1920"), "{text}");
    assert!(text.contains("codec_type=audio"), "{text}");
    let expected = frames as f64 / FPS as f64;
    let durations: Vec<f64> = text
        .lines()
        .filter_map(|line| line.split("duration=").nth(1))
        .filter_map(|value| value.trim().parse().ok())
        .collect();
    assert!(durations.iter().all(|duration| (duration - expected).abs() < 0.1), "{durations:?} vs {expected}");
    let cancelled = directory.join("cancelled.mp4");
    let outcome = export::export_video(scene.clone(), &audio, &cancelled, &AtomicBool::new(true), |_| {});
    assert_eq!(outcome, Err(ExportError::Cancelled));
    assert!(!cancelled.exists());
    let card = directory.join("card.png");
    export::export_image(scene, &card).expect("image");
    assert!(card.metadata().map(|meta| meta.len() > 10_000).unwrap_or(false));
    if let Some(shots) = shots() {
        let _ = std::fs::copy(&out, shots.join("clip.mp4"));
    }
    let _ = std::fs::remove_dir_all(&directory);
}

#[test]
fn audio_is_read_from_a_file_faded_at_the_clip_rate() {
    if crate::downloads::resolve_tool("ffmpeg").is_none() {
        return;
    }
    let directory = std::env::temp_dir().join(format!("flaccy-lyric-share-audio-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&directory);
    let source = directory.join("tone.flac");
    let made = std::process::Command::new(crate::downloads::resolve_tool("ffmpeg").expect("ffmpeg"))
        .args(["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=96000:duration=10"])
        .args(["-c:a", "flac"])
        .arg(&source)
        .status()
        .expect("ffmpeg");
    assert!(made.success());
    let clip = flaccy_shared::lyric_share::Window { lyric_start: 2.0, duration: 6.0, offset: 0.5 };
    let rate = export::target_rate(Some(96_000));
    assert_eq!(rate, 48_000);
    assert_eq!(export::target_rate(Some(88_200)), 44_100);
    assert_eq!(export::target_rate(None), 48_000);
    let audio = export::load_audio(source.to_str().expect("path"), &clip, rate).expect("audio");
    assert_eq!(audio.sample_rate, 48_000);
    assert!((audio.duration() - 6.0).abs() < 0.02, "{}", audio.duration());
    assert!(audio.interleaved[0].abs() < 1e-3, "the clip fades in");
    let middle = audio.frame_count() / 2;
    let peak = audio.interleaved[middle * 2..middle * 2 + 400].iter().fold(0.0f32, |a, b| a.max(b.abs()));
    assert!(peak > 0.05, "the middle is audible: {peak}");
    let wav = directory.join("preview.wav");
    export::write_wav(&audio, &wav).expect("wav");
    assert_eq!(wav.metadata().expect("meta").len() as usize, 44 + audio.interleaved.len() * 4);
    let past = flaccy_shared::lyric_share::Window { lyric_start: 30.0, duration: 6.0, offset: 0.0 };
    assert!(export::load_audio(source.to_str().expect("path"), &past, rate).is_err());
    let _ = std::fs::remove_dir_all(&directory);
}
