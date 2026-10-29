//! Lyric clips: the chosen lines of a song drawn over its own audio, as an
//! MP4 to post or a PNG card. The rules (which lines, the window of audio,
//! the layout, the motion, the palette, the visualizer) are
//! `flaccy_shared::lyric_share`, mirrored from FlaccyCore; this module paints
//! them with Cairo and Pango and encodes them with ffmpeg, the way the Apple
//! clients do with Core Graphics and AVFoundation.

pub mod copy;
pub mod export;
pub mod render;

use flaccy_shared::lyric_share::{frame_count, Analysis, Palette, Selection, Style, Window};
use flaccy_shared::lyrics::Document;
use std::sync::Arc;

/// A cover as Cairo paints it: premultiplied ARGB32 in native byte order.
pub struct Cover {
    pub data: Vec<u8>,
    pub width: i32,
    pub height: i32,
    pub stride: i32,
}

impl Cover {
    /// A cover from straight RGBA pixels.
    #[cfg(test)]
    pub fn from_rgba(rgba: &[u8], width: u32, height: u32) -> Self {
        let mut data = Vec::with_capacity(rgba.len());
        for pixel in rgba.chunks_exact(4) {
            let alpha = pixel[3] as u32;
            let scale = |channel: u8| ((channel as u32 * alpha + 127) / 255) as u8;
            data.extend_from_slice(&[scale(pixel[2]), scale(pixel[1]), scale(pixel[0]), pixel[3]]);
        }
        Self {
            data,
            width: width as i32,
            height: height as i32,
            stride: width as i32 * 4,
        }
    }

    /// A grid of colour samples across the cover, for the palette.
    pub fn samples(&self) -> Vec<flaccy_shared::lyric_share::Color> {
        let grid = 12;
        let mut samples = Vec::with_capacity(grid * grid);
        for row in 0..grid {
            for column in 0..grid {
                let x = ((column as f64 + 0.5) / grid as f64 * self.width as f64) as i32;
                let y = ((row as f64 + 0.5) / grid as f64 * self.height as f64) as i32;
                let at = (y.clamp(0, self.height - 1) * self.stride + x.clamp(0, self.width - 1) * 4) as usize;
                let alpha = self.data[at + 3].max(1) as f64;
                let channel = |value: u8| (value as f64 / alpha).min(1.0);
                samples.push(flaccy_shared::lyric_share::Color {
                    red: channel(self.data[at + 2]),
                    green: channel(self.data[at + 1]),
                    blue: channel(self.data[at]),
                });
            }
        }
        samples
    }
}

/// Everything a clip is drawn from. `plain_lines` is set for lyrics without
/// timing, whose card shows the chosen lines all at once.
#[derive(Clone)]
pub struct Scene {
    pub document: Arc<Document>,
    pub selection: Selection,
    pub plain_lines: Option<Arc<Vec<String>>>,
    pub window: Window,
    pub style: Style,
    pub palette: Palette,
    pub title: String,
    pub artist: String,
    pub cover: Option<Arc<Cover>>,
    pub analysis: Arc<Analysis>,
}

impl Scene {
    pub fn is_timed(&self) -> bool {
        self.plain_lines.is_none()
    }

    pub fn frame_count(&self) -> usize {
        frame_count(&self.window)
    }
}

#[cfg(test)]
mod tests;
