//! How the lines of a clip move from frame to frame, and the shape of the audio
//! picture each template draws.
//!
//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/LyricShare/LyricShareMotion.swift`,
//! so every client animates the same template the same way.

use super::clip::Selection;
use super::style::Template;
use crate::lyrics::Document;

/// The selected line a frame is about and how far it has come in, 0 to 1.
/// `rank` is its place among the selection's sung lines.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Focus {
    pub index: usize,
    pub rank: usize,
    pub entrance: f64,
}

/// How long a line takes to come in.
pub const ENTRANCE_DURATION: f64 = 0.42;
/// How far ahead of its start a line begins to come in, so it has landed
/// by the time it is sung.
pub const ENTRANCE_LEAD: f64 = 0.12;
/// How bright a line is that is not the one being sung.
pub const DIM: f64 = 0.34;
/// How far, in line heights of the lyric size, a line rises as it comes in
/// and the one before it rises as it leaves.
pub const RISE: f64 = 0.35;

/// The share of each bar's slot left empty between bars.
pub const GAP_RATIO: f64 = 0.44;
/// The shortest bar, as a share of the strip's height, so silence still
/// reads as a strip.
pub const MINIMUM_BAR: f64 = 0.08;
/// The ring around the pulse disc starts this far out, in disc radii.
pub const RING_INNER: f64 = 1.1;
/// The longest ring bar, in disc radii.
pub const RING_LENGTH: f64 = 0.32;
/// How much the pulse disc grows at full level.
pub const DISC_PULSE: f64 = 0.05;

/// The selection's sung lines, in order: the run without its interludes.
pub fn lines_of(selection: Selection, document: &Document) -> Vec<usize> {
    (selection.first..=selection.last)
        .filter(|&index| !document.lines[index].is_interlude())
        .collect()
}

/// The selected line a frame at `time` is about: the last one to have
/// started coming in, or the first while none has. The first line comes
/// in with the clip itself.
pub fn focus(selection: Selection, document: &Document, time: f64, clip_start: f64) -> Focus {
    let sung = lines_of(selection, document);
    let mut rank = 0;
    for (position, &index) in sung.iter().enumerate() {
        if document.lines[index].start - ENTRANCE_LEAD <= time {
            rank = position;
        }
    }
    let index = sung[rank];
    let from = if rank == 0 {
        clip_start
    } else {
        document.lines[index].start - ENTRANCE_LEAD
    };
    Focus {
        index,
        rank,
        entrance: ease((time - from) / ENTRANCE_DURATION),
    }
}

/// Ease-out cubic over 0 to 1, clamped.
pub fn ease(x: f64) -> f64 {
    let clamped = x.clamp(0.0, 1.0);
    let rest = 1.0 - clamped;
    1.0 - rest * rest * rest
}

/// Where a scrolling stack stands: the focused line's rank, reached as it
/// comes in, so the stack glides from one line to the next.
pub fn scroll_position(focus: &Focus) -> f64 {
    if focus.rank == 0 {
        0.0
    } else {
        (focus.rank - 1) as f64 + focus.entrance
    }
}

/// How bright the line at `rank` is in a frame. A verse lights the line
/// being sung and lets the one before it go; a poster keeps every sung
/// line lit; spotlight and pulse show one line, so the value is its
/// opacity as one crossfades into the next.
pub fn ink(rank: usize, focus: &Focus, template: Template) -> f64 {
    let entrance = focus.entrance;
    match template {
        Template::Verse => {
            if rank == focus.rank {
                DIM + (1.0 - DIM) * entrance
            } else if rank + 1 == focus.rank {
                1.0 - (1.0 - DIM) * entrance
            } else {
                DIM
            }
        }
        Template::Poster => {
            if rank < focus.rank {
                1.0
            } else if rank == focus.rank {
                DIM + (1.0 - DIM) * entrance
            } else {
                DIM
            }
        }
        Template::Spotlight | Template::Pulse => {
            if rank == focus.rank {
                entrance
            } else if rank + 1 == focus.rank {
                1.0 - entrance
            } else {
                0.0
            }
        }
    }
}

/// A strip's bars: the bands mirrored, lows in the middle.
pub fn strip(bands: &[f32]) -> Vec<f32> {
    bands.iter().rev().chain(bands.iter()).copied().collect()
}

/// A ring's bars clockwise from the top: lows at the top, the highs
/// meeting at the bottom.
pub fn ring(bands: &[f32]) -> Vec<f32> {
    bands.iter().chain(bands.iter().rev()).copied().collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lyric_share::test_support::song;

    fn assert_close(actual: f64, expected: f64) {
        assert!((actual - expected).abs() < 1e-9, "{actual} != {expected}");
    }

    #[test]
    fn focus_follows_the_sung_lines_with_a_lead() {
        let doc = song();
        let selection = Selection { first: 2, last: 5 };
        assert_eq!(lines_of(selection, &doc), vec![2, 3, 5]);
        let opening = focus(selection, &doc, 6.4, 6.4);
        assert_eq!(
            opening,
            Focus {
                index: 2,
                rank: 0,
                entrance: 0.0
            }
        );
        let landing = focus(selection, &doc, 6.61, 6.4);
        assert_close(landing.entrance, 0.875);
        let second = focus(selection, &doc, 9.88 + 0.21, 6.4);
        assert_eq!(second.index, 3);
        assert_eq!(second.rank, 1);
        assert_close(second.entrance, 0.875);
        assert_eq!(
            focus(selection, &doc, 30.0, 6.4),
            Focus {
                index: 5,
                rank: 2,
                entrance: 1.0
            }
        );
        assert_close(scroll_position(&second), 0.875);
        assert_close(scroll_position(&opening), 0.0);
    }

    #[test]
    fn ink_per_template() {
        let focus = Focus {
            index: 3,
            rank: 1,
            entrance: 0.5,
        };
        assert_close(ink(1, &focus, Template::Verse), 0.67);
        assert_close(ink(0, &focus, Template::Verse), 0.67);
        assert_close(ink(2, &focus, Template::Verse), 0.34);
        assert_close(ink(0, &focus, Template::Poster), 1.0);
        assert_close(ink(2, &focus, Template::Poster), 0.34);
        assert_close(ink(1, &focus, Template::Spotlight), 0.5);
        assert_close(ink(0, &focus, Template::Pulse), 0.5);
        assert_close(ink(2, &focus, Template::Spotlight), 0.0);
        assert_close(ease(0.5), 0.875);
        assert_close(ease(-3.0), 0.0);
        assert_close(ease(4.0), 1.0);
    }

    #[test]
    fn visualizer_mirrors_the_bands() {
        assert_eq!(strip(&[1.0, 2.0, 3.0]), vec![3.0, 2.0, 1.0, 1.0, 2.0, 3.0]);
        assert_eq!(ring(&[1.0, 2.0, 3.0]), vec![1.0, 2.0, 3.0, 3.0, 2.0, 1.0]);
    }
}
