//! Lyric share clips: the look of a clip, which lines it holds, and how its
//! frames, bars, palette and layout are worked out.
//!
//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/LyricShare` and is covered by the
//! same vectors, so every client picks the same lines, frames, bars and palette
//! for the same song.

mod clip;
mod layout;
mod motion;
mod palette;
mod spectrum;
mod style;

pub use clip::{
    default_plain_selection, default_selection, fits, frame_count, gain, is_selectable,
    plain_lines, plain_window, span, time_of_frame, toggle, toggle_plain, window, Selection,
    Window, DEFAULT_LINES, DEFAULT_SPAN, FADE_IN, FADE_OUT, FPS, LEAD_IN, MAX_DURATION,
    MAX_PLAIN_LINES, MIN_DURATION, PLAIN_DURATION, TAIL,
};
pub use layout::{
    base_lyric_size, file_name, safe_area, Alignment, Layout, Rect, HEADER_GAP, HEADER_HEIGHT,
    MARK_GAP, MARK_HEIGHT, MARK_SIZE, MAXIMUM_NAME_LENGTH, MINIMUM_LYRIC_SCALE, STRIP_GAP,
    STRIP_HEIGHT, WAVE_GAP, WAVE_HEIGHT,
};
pub use motion::{
    ease, focus, ink, lines_of, ring, scroll_position, strip, Focus, DIM, DISC_PULSE,
    ENTRANCE_DURATION, ENTRANCE_LEAD, GAP_RATIO, MINIMUM_BAR, RING_INNER, RING_LENGTH, RISE,
};
pub use palette::{Color, Palette};
pub use spectrum::{
    analyze, band_edges, Analysis, ATTACK, BAND_COUNT, BAND_FLOOR_DB, FFT_SIZE, HIGH_HZ,
    LEVEL_FLOOR_DB, LOW_HZ, RELEASE,
};
pub use style::{Format, Style, Template, Theme, Typeface};

#[cfg(test)]
pub(crate) mod test_support {
    use crate::lyrics::{Document, RawLine};

    /// A raw lyric line with its end given, the shape a source hands to `Document::resolve`.
    pub(crate) fn raw(start: f64, end: f64, text: &str) -> RawLine {
        RawLine {
            start,
            end: Some(end),
            text: text.to_string(),
            words: Vec::new(),
        }
    }

    /// Lines 0–3, an interlude at index 4, then lines 5–8, with "hold on" sung
    /// three times.
    pub(crate) fn song() -> Document {
        Document::resolve(
            vec![
                raw(1.0, 4.0, "Streetlights hum"),
                raw(4.0, 7.0, "Hold on, hold on!"),
                raw(7.0, 10.0, "We were young"),
                raw(10.0, 13.0, "Hold on hold on"),
                raw(20.0, 23.0, "Second verse"),
                raw(23.0, 26.0, "hold on, HOLD ON"),
                raw(26.0, 40.0, "A very long held note"),
                raw(40.0, 44.0, "Outro"),
            ],
            None,
            false,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::song;

    #[test]
    fn the_document_under_test_has_one_interlude() {
        let doc = song();
        assert_eq!(doc.lines.len(), 9);
        assert!(!doc.lines[0].is_interlude());
        assert_eq!(
            doc.lines.iter().filter(|line| line.is_interlude()).count(),
            1
        );
        assert!(doc.lines[4].is_interlude());
    }
}
