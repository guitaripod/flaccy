//! The words of the lyric share dialog, the same English as the Apple
//! clients' `Features/LyricShare/LyricShareCopy.swift`.

use super::export::ExportError;
use flaccy_shared::lyric_share::{Format, Template, Theme, Typeface};

pub const SHEET_TITLE: &str = "Share Lyrics";
pub const FROM_LINE: &str = "Share from This Line";
pub const TEMPLATE_HEADER: &str = "Template";
pub const FORMAT_HEADER: &str = "Format";
pub const COLORS_HEADER: &str = "Colors";
pub const FONT_HEADER: &str = "Font";
pub const LINES_HEADER: &str = "Lines";
pub const SHOW_COVER: &str = "Cover";
pub const SHOW_VISUALIZER: &str = "Visualizer";
pub const SHOW_MARK: &str = "Flaccy Mark";
pub const SAVE_VIDEO: &str = "Save Video…";
pub const SAVE_IMAGE: &str = "Save Image…";
pub const MAKING: &str = "Making your video…";
pub const PLAY_PREVIEW: &str = "Play Preview";
pub const PAUSE_PREVIEW: &str = "Pause Preview";
pub const READING_AUDIO: &str = "Reading the song…";

pub fn template(template: Template) -> &'static str {
    match template {
        Template::Spotlight => "Spotlight",
        Template::Verse => "Verse",
        Template::Poster => "Poster",
        Template::Pulse => "Pulse",
    }
}

pub fn template_hint(template: Template) -> &'static str {
    match template {
        Template::Spotlight => "One big line at a time",
        Template::Verse => "The verse scrolls past",
        Template::Poster => "Cover art with every line",
        Template::Pulse => "A disc that moves with the music",
    }
}

pub fn template_icon(template: Template) -> &'static str {
    match template {
        Template::Spotlight => "format-justify-center-symbolic",
        Template::Verse => "format-justify-left-symbolic",
        Template::Poster => "image-x-generic-symbolic",
        Template::Pulse => "media-playlist-repeat-symbolic",
    }
}

pub fn format(format: Format) -> &'static str {
    match format {
        Format::Story => "Story",
        Format::Portrait => "Post",
        Format::Square => "Square",
        Format::Wide => "Wide",
    }
}

pub fn theme(theme: Theme) -> &'static str {
    match theme {
        Theme::Artwork => "Artwork",
        Theme::Vivid => "Vivid",
        Theme::Dark => "Dark",
        Theme::Light => "Light",
    }
}

pub fn typeface(typeface: Typeface) -> &'static str {
    match typeface {
        Typeface::Modern => "Modern",
        Typeface::Serif => "Serif",
        Typeface::Rounded => "Rounded",
        Typeface::Mono => "Mono",
    }
}

pub fn clock(seconds: f64) -> String {
    let whole = seconds.round().max(0.0) as i64;
    format!("{}:{:02}", whole / 60, whole % 60)
}

/// The length of the clip and how to change the lines.
pub fn lines_hint(duration: f64, timed: bool) -> String {
    let length = clock(duration);
    if timed {
        format!("{length} clip · Tap lines to choose up to 30 seconds.")
    } else {
        format!("{length} clip · Tap lines to choose up to 6.")
    }
}

pub fn starts_at(seconds: f64) -> String {
    format!("Music starts at {}", clock(seconds))
}

pub fn audio_failure(error: &ExportError, song: &str) -> String {
    match error {
        ExportError::MissingFfmpeg => format!(
            "Couldn't read the audio of “{song}” — ffmpeg isn't installed. Install it (pacman -S ffmpeg) to make videos; you can still save an image."
        ),
        ExportError::OutOfRange => format!(
            "Couldn't read the audio of “{song}” — the chosen lines lie past the end of the file. Pick earlier lines."
        ),
        ExportError::Unreadable(reason) | ExportError::Encoder(reason) | ExportError::Image(reason) => format!(
            "Couldn't read the audio of “{song}” ({reason}). You can still save an image."
        ),
        ExportError::Cancelled => "Stopped reading the song.".to_string(),
    }
}

pub fn export_failure(error: &ExportError) -> String {
    match error {
        ExportError::Cancelled => "Stopped making the video.".to_string(),
        ExportError::MissingFfmpeg => {
            "Couldn't make the video — ffmpeg isn't installed. Install it (pacman -S ffmpeg) and try again, or save an image instead.".to_string()
        }
        ExportError::Image(reason) => format!("Couldn't make the image ({reason}). Check free space and try again."),
        ExportError::Unreadable(reason) | ExportError::Encoder(reason) => {
            format!("Couldn't make the video ({reason}). Try again, or save an image instead.")
        }
        ExportError::OutOfRange => {
            "Couldn't make the video — the chosen lines lie past the end of the file. Pick earlier lines.".to_string()
        }
    }
}
