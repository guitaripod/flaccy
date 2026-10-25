//! Which lines a lyric clip starts with, how a tap changes them, and the stretch
//! of audio and frames that follow.
//!
//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/LyricShare/LyricShareClip.swift`.
//! A selection indexes `Document::lines` for synced lyrics and the lines from
//! `plain_lines` for unsynced ones.

use crate::lyrics::Document;
use std::collections::{HashMap, HashSet};

/// The lines a clip holds, as the first and last index of a run of lines.
/// For synced lyrics both index `Document::lines` and are never an
/// interlude; for plain lyrics they index `plain_lines`'s output.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Selection {
    pub first: usize,
    pub last: usize,
}

impl Selection {
    /// Whether `index` falls inside the run.
    pub fn contains(self, index: usize) -> bool {
        (self.first..=self.last).contains(&index)
    }
}

/// The stretch of the song a clip plays. `lyric_start` is on the lyrics clock;
/// the audio is that moment plus the listener's timing correction.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Window {
    pub lyric_start: f64,
    pub duration: f64,
    pub offset: f64,
}

impl Window {
    /// Where the audio starts: the lyric start plus the timing correction.
    pub fn audio_start(&self) -> f64 {
        self.lyric_start + self.offset
    }

    /// Where the lyric clock stops.
    pub fn lyric_end(&self) -> f64 {
        self.lyric_start + self.duration
    }
}

/// The longest clip: what every story and short-video app takes whole.
pub const MAX_DURATION: f64 = 30.0;
/// The shortest clip, so a single short line still has music around it.
pub const MIN_DURATION: f64 = 6.0;
/// Music before the first line, so the clip does not open mid-breath.
pub const LEAD_IN: f64 = 0.6;
/// Music after the last line ends.
pub const TAIL: f64 = 1.4;
/// How long the lines a clip starts with may run.
pub const DEFAULT_SPAN: f64 = 15.0;
/// How many lines a clip starts with at most.
pub const DEFAULT_LINES: usize = 4;
/// How many plain lines one card holds, since they are all on screen at once.
pub const MAX_PLAIN_LINES: usize = 6;
/// How long a clip of plain lyrics plays.
pub const PLAIN_DURATION: f64 = 15.0;
/// The frame rate every clip is rendered at.
pub const FPS: u32 = 30;
/// How long a clip takes to fade in from silence.
pub const FADE_IN: f64 = 0.3;
/// How long a clip takes to fade out to silence.
pub const FADE_OUT: f64 = 0.9;

/// The lines of plain lyrics a card can hold: trimmed, blank ones dropped.
pub fn plain_lines(plain: &str) -> Vec<String> {
    plain
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect()
}

/// Whether `index` names a sung line of the document.
pub fn is_selectable(index: usize, document: &Document) -> bool {
    document
        .lines
        .get(index)
        .is_some_and(|line| !line.is_interlude())
}

/// The lines a clip starts with. With the song's clock, the line being sung or the
/// next one to come; without it, the chorus, else the first line. Then the lines
/// after it while they fit the default span.
pub fn default_selection(document: &Document, time: Option<f64>) -> Option<Selection> {
    let texts = text_indices(document);
    let first_text = *texts.first()?;
    let last_text = *texts.last()?;
    let start = match time {
        Some(time) => match document.primary_index(time) {
            Some(primary)
                if !document.lines[primary].is_interlude()
                    && time < document.lines[primary].end =>
            {
                primary
            }
            _ => texts
                .iter()
                .copied()
                .find(|&index| document.lines[index].start > time)
                .unwrap_or(last_text),
        },
        None => chorus_start(document, &texts).unwrap_or(first_text),
    };
    let mut last = start;
    let mut count = 1;
    while count < DEFAULT_LINES {
        let Some(next) = next_text(last, document) else {
            break;
        };
        if document.lines[next].end - document.lines[start].start > DEFAULT_SPAN {
            break;
        }
        last = next;
        count += 1;
    }
    Some(Selection { first: start, last })
}

/// The first plain lines, or from the chorus when one line repeats.
pub fn default_plain_selection(lines: &[String]) -> Option<Selection> {
    if lines.is_empty() {
        return None;
    }
    let keys: Vec<String> = lines.iter().map(|line| normalized(line)).collect();
    let first = most_repeated(&keys).unwrap_or(0);
    let last = (first + DEFAULT_LINES - 1).min(lines.len() - 1);
    Some(Selection { first, last })
}

/// What a tap on a line makes of the selection, which always stays one
/// unbroken run. A line outside it extends the run to reach it, letting go
/// of lines at the far end if the clip would grow too long; the first or
/// last line drops out; a line inside becomes the new last line. The last
/// remaining line cannot be taken away.
pub fn toggle(selection: Selection, index: usize, document: &Document) -> Selection {
    if !is_selectable(index, document) {
        return selection;
    }
    let mut next = selection;
    if index < selection.first {
        next.first = index;
        while !fits(next, document) && next.last > index {
            let Some(earlier) = previous_text(next.last, document) else {
                break;
            };
            next.last = earlier;
        }
    } else if index > selection.last {
        next.last = index;
        while !fits(next, document) && next.first < index {
            let Some(later) = next_text(next.first, document) else {
                break;
            };
            next.first = later;
        }
    } else if selection.first == selection.last {
        return selection;
    } else if index == selection.first {
        next.first = next_text(index, document).unwrap_or(selection.first);
    } else if index == selection.last {
        next.last = previous_text(index, document).unwrap_or(selection.last);
    } else {
        next.last = index;
    }
    next
}

/// The same rule for plain lines, where the limit is a count rather than a
/// length of time.
pub fn toggle_plain(selection: Selection, index: usize, count: usize) -> Selection {
    if index >= count {
        return selection;
    }
    let mut next = selection;
    if index < selection.first {
        next.first = index;
        next.last = next.last.min(index + MAX_PLAIN_LINES - 1);
    } else if index > selection.last {
        next.last = index;
        next.first = next.first.max(index.saturating_sub(MAX_PLAIN_LINES - 1));
    } else if selection.first == selection.last {
        return selection;
    } else if index == selection.first {
        next.first += 1;
    } else if index == selection.last {
        next.last -= 1;
    } else {
        next.last = index;
    }
    next
}

/// From the first selected line's start to the last one's end.
pub fn span(selection: Selection, document: &Document) -> f64 {
    document.lines[selection.last].end - document.lines[selection.first].start
}

/// A single line always fits; a longer run fits while it and the lead-in
/// play within the longest clip. The tail is trimmed before a line is.
pub fn fits(selection: Selection, document: &Document) -> bool {
    selection.first == selection.last || span(selection, document) + LEAD_IN <= MAX_DURATION
}

/// The stretch a selection plays: a breath before the first line, the
/// tail after the last, at least the shortest clip and at most the
/// longest, never before the song starts or past its end.
pub fn window(
    selection: Selection,
    document: &Document,
    offset: f64,
    track_duration: f64,
) -> Window {
    let first = &document.lines[selection.first];
    let last = &document.lines[selection.last];
    let floor = (-offset).max(0.0);
    let mut start = (first.start - LEAD_IN).max(floor);
    let mut end = (last.end + TAIL).max(start + MIN_DURATION);
    end = end.min(start + MAX_DURATION);
    if track_duration > 0.0 {
        let limit = track_duration - offset;
        if end > limit {
            end = limit;
            start = (end - MIN_DURATION).min(start).max(floor);
        }
    }
    Window {
        lyric_start: start,
        duration: (end - start).max(0.0),
        offset,
    }
}

/// The stretch a card of plain lyrics plays, from where the listener chose.
pub fn plain_window(start: f64, track_duration: f64) -> Window {
    let mut from = start.max(0.0);
    let mut duration = PLAIN_DURATION;
    if track_duration > 0.0 {
        from = from.min((track_duration - PLAIN_DURATION).max(0.0));
        duration = PLAIN_DURATION.min(track_duration - from);
    }
    Window {
        lyric_start: from,
        duration: duration.max(0.0),
        offset: 0.0,
    }
}

/// How many frames a window renders, at least one.
pub fn frame_count(window: &Window) -> usize {
    (window.duration * f64::from(FPS) - 1e-9).ceil().max(1.0) as usize
}

/// The lyrics clock at a frame of the clip.
pub fn time_of_frame(frame: usize, window: &Window) -> f64 {
    window.lyric_start + frame as f64 / f64::from(FPS)
}

/// How loud the clip's audio is at `time` seconds into it: a short fade in
/// and a longer fade out, each an S-curve.
pub fn gain(time: f64, duration: f64) -> f64 {
    if !(0.0..=duration).contains(&time) {
        return 0.0;
    }
    let rise = time / FADE_IN;
    let fall = (duration - time) / FADE_OUT;
    let x = rise.min(fall).clamp(0.0, 1.0);
    x * x * (3.0 - 2.0 * x)
}

/// The indices of the lines a clip may start on: every line but the interludes.
fn text_indices(document: &Document) -> Vec<usize> {
    document
        .lines
        .iter()
        .enumerate()
        .filter(|(_, line)| !line.is_interlude())
        .map(|(index, _)| index)
        .collect()
}

/// The first sung line after `after`, skipping interludes.
pub(crate) fn next_text(after: usize, document: &Document) -> Option<usize> {
    document
        .lines
        .iter()
        .enumerate()
        .skip(after + 1)
        .find(|(_, line)| !line.is_interlude())
        .map(|(index, _)| index)
}

/// The last sung line before `before`, skipping interludes.
pub(crate) fn previous_text(before: usize, document: &Document) -> Option<usize> {
    document
        .lines
        .iter()
        .take(before)
        .rposition(|line| !line.is_interlude())
}

/// The first time the most repeated line is sung, when any line repeats.
fn chorus_start(document: &Document, texts: &[usize]) -> Option<usize> {
    let keys: Vec<String> = texts
        .iter()
        .map(|&index| normalized(&document.lines[index].text))
        .collect();
    most_repeated(&keys).map(|position| texts[position])
}

/// The position of the first occurrence of the key that occurs most often,
/// the earliest such key on a tie, or `None` when nothing repeats.
pub(crate) fn most_repeated(keys: &[String]) -> Option<usize> {
    let mut counts: HashMap<&str, usize> = HashMap::new();
    for key in keys.iter().filter(|key| !key.is_empty()) {
        *counts.entry(key.as_str()).or_insert(0) += 1;
    }
    let mut seen: HashSet<&str> = HashSet::new();
    let mut best: Option<(usize, usize)> = None;
    for (position, key) in keys.iter().enumerate() {
        if key.is_empty() || !seen.insert(key.as_str()) {
            continue;
        }
        let count = counts.get(key.as_str()).copied().unwrap_or(0);
        if count >= 2 && count > best.map_or(0, |(_, best_count)| best_count) {
            best = Some((position, count));
        }
    }
    best.map(|(position, _)| position)
}

/// Lowercase letters and digits with single spaces between words, so
/// "Hold on!" and "hold on" are one line.
pub(crate) fn normalized(text: &str) -> String {
    text.to_lowercase()
        .split(|character: char| !character.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lyric_share::test_support::{raw, song};

    fn assert_close(actual: f64, expected: f64) {
        assert!((actual - expected).abs() < 1e-9, "{actual} != {expected}");
    }

    fn keys(words: &[&str]) -> Vec<String> {
        words.iter().map(|word| word.to_string()).collect()
    }

    #[test]
    fn default_selection_follows_the_clock() {
        let doc = song();
        assert_eq!(
            default_selection(&doc, Some(5.0)),
            Some(Selection { first: 1, last: 3 })
        );
        assert_eq!(
            default_selection(&doc, Some(0.2)),
            Some(Selection { first: 0, last: 3 })
        );
        assert_eq!(
            default_selection(&doc, Some(15.0)),
            Some(Selection { first: 5, last: 6 })
        );
        assert_eq!(
            default_selection(&doc, Some(999.0)),
            Some(Selection { first: 8, last: 8 })
        );
    }

    #[test]
    fn without_a_clock_the_default_selection_starts_at_the_chorus() {
        let doc = song();
        assert_eq!(
            default_selection(&doc, None),
            Some(Selection { first: 1, last: 3 })
        );
        let plain_doc = Document::resolve(
            vec![
                raw(0.0, 2.0, "one"),
                raw(2.0, 4.0, "two"),
                raw(4.0, 6.0, "three"),
            ],
            None,
            false,
        );
        assert_eq!(
            default_selection(&plain_doc, None),
            Some(Selection { first: 0, last: 2 })
        );
        assert_eq!(default_selection(&Document::default(), Some(3.0)), None);
    }

    #[test]
    fn default_selection_stops_at_the_span() {
        let doc = song();
        assert_eq!(
            default_selection(&doc, Some(24.0)),
            Some(Selection { first: 6, last: 6 })
        );
    }

    #[test]
    fn normalization_ignores_case_and_punctuation() {
        assert_eq!(normalized("  Hold on, HOLD   on!! "), "hold on hold on");
        assert_eq!(normalized("Ça va? 99 Luftballons"), "ça va 99 luftballons");
        assert_eq!(normalized("♪ ... ♪"), "");
        assert_eq!(most_repeated(&keys(&["a", "b", "c"])), None);
        assert_eq!(
            most_repeated(&keys(&["a", "b", "b", "a", "c", "b"])),
            Some(1)
        );
        assert_eq!(most_repeated(&keys(&["x", "a", "b", "a", "b"])), Some(1));
        assert_eq!(most_repeated(&keys(&["", "", "q"])), None);
    }

    #[test]
    fn toggling_extends_shrinks_and_keeps_the_last_line() {
        let doc = song();
        let one = Selection { first: 2, last: 2 };
        assert_eq!(toggle(one, 2, &doc), one);
        assert_eq!(toggle(one, 0, &doc), Selection { first: 0, last: 2 });
        assert_eq!(toggle(one, 5, &doc), Selection { first: 2, last: 5 });
        assert_eq!(toggle(one, 4, &doc), one);
        assert_eq!(toggle(one, 42, &doc), one);
        let run = Selection { first: 1, last: 5 };
        assert_eq!(toggle(run, 1, &doc), Selection { first: 2, last: 5 });
        assert_eq!(toggle(run, 5, &doc), Selection { first: 1, last: 3 });
        assert_eq!(
            toggle(Selection { first: 3, last: 5 }, 5, &doc),
            Selection { first: 3, last: 3 }
        );
        assert_eq!(
            toggle(Selection { first: 3, last: 5 }, 3, &doc),
            Selection { first: 5, last: 5 }
        );
        assert_eq!(toggle(run, 2, &doc), Selection { first: 1, last: 2 });
    }

    #[test]
    fn extending_past_the_longest_clip_lets_go_of_the_far_end() {
        let doc = song();
        let start = Selection { first: 0, last: 1 };
        assert_eq!(toggle(start, 8, &doc), Selection { first: 5, last: 8 });
        assert_eq!(
            toggle(Selection { first: 7, last: 8 }, 0, &doc),
            Selection { first: 0, last: 6 }
        );
        assert!(fits(Selection { first: 5, last: 8 }, &doc));
        assert!(!fits(Selection { first: 3, last: 8 }, &doc));
        assert_close(span(Selection { first: 0, last: 3 }, &doc), 12.0);
    }

    #[test]
    fn plain_toggling_caps_the_count() {
        let full = Selection { first: 0, last: 5 };
        assert_eq!(toggle_plain(full, 7, 10), Selection { first: 2, last: 7 });
        assert_eq!(
            toggle_plain(Selection { first: 4, last: 9 }, 1, 10),
            Selection { first: 1, last: 6 }
        );
        assert_eq!(toggle_plain(full, 0, 10), Selection { first: 1, last: 5 });
        assert_eq!(toggle_plain(full, 5, 10), Selection { first: 0, last: 4 });
        assert_eq!(toggle_plain(full, 3, 10), Selection { first: 0, last: 3 });
        assert_eq!(
            toggle_plain(Selection { first: 2, last: 2 }, 2, 10),
            Selection { first: 2, last: 2 }
        );
        assert_eq!(toggle_plain(full, 10, 10), full);
    }

    #[test]
    fn plain_lines_and_their_default_selection() {
        let lines = plain_lines("  First\r\n\nSecond  \n   \nChorus!\nchorus\nLast\n");
        assert_eq!(lines, vec!["First", "Second", "Chorus!", "chorus", "Last"]);
        assert_eq!(
            default_plain_selection(&lines),
            Some(Selection { first: 2, last: 4 })
        );
        assert_eq!(
            default_plain_selection(&keys(&["a", "b"])),
            Some(Selection { first: 0, last: 1 })
        );
        assert_eq!(default_plain_selection(&[]), None);
    }

    #[test]
    fn the_window_breathes_around_the_lines() {
        let doc = song();
        let window = window(Selection { first: 1, last: 2 }, &doc, 0.0, 200.0);
        assert_close(window.lyric_start, 3.4);
        assert_close(window.duration, 8.0);
        assert_close(window.audio_start(), 3.4);
        let short = window_for_short_line(&doc);
        assert_close(short.lyric_start, 0.4);
        assert_close(short.duration, 6.0);
    }

    /// The window of the first line alone, at offset zero in a 200 second song.
    fn window_for_short_line(doc: &Document) -> Window {
        window(Selection { first: 0, last: 0 }, doc, 0.0, 200.0)
    }

    #[test]
    fn the_window_applies_the_offset_and_stays_inside_the_song() {
        let doc = song();
        let later = window(Selection { first: 0, last: 1 }, &doc, 1.5, 200.0);
        assert_close(later.lyric_start, 0.4);
        assert_close(later.audio_start(), 1.9);
        let earlier = window(Selection { first: 0, last: 1 }, &doc, -2.0, 200.0);
        assert_close(earlier.lyric_start, 2.0);
        assert_close(earlier.audio_start(), 0.0);
        let at_end = window(Selection { first: 8, last: 8 }, &doc, 0.0, 44.5);
        assert_close(at_end.lyric_start, 38.5);
        assert_close(at_end.duration, 6.0);
        let long = window(Selection { first: 0, last: 8 }, &doc, 0.0, 0.0);
        assert_close(long.lyric_start, 0.4);
        assert_close(long.duration, 30.0);
    }

    #[test]
    fn the_plain_window_is_fifteen_seconds_inside_the_song() {
        assert_eq!(
            plain_window(30.0, 200.0),
            Window {
                lyric_start: 30.0,
                duration: 15.0,
                offset: 0.0
            }
        );
        assert_eq!(
            plain_window(195.0, 200.0),
            Window {
                lyric_start: 185.0,
                duration: 15.0,
                offset: 0.0
            }
        );
        assert_eq!(
            plain_window(-4.0, 10.0),
            Window {
                lyric_start: 0.0,
                duration: 10.0,
                offset: 0.0
            }
        );
        assert_eq!(
            plain_window(12.0, 0.0),
            Window {
                lyric_start: 12.0,
                duration: 15.0,
                offset: 0.0
            }
        );
    }

    #[test]
    fn frames_and_gain() {
        let fifteen = Window {
            lyric_start: 0.0,
            duration: 15.0,
            offset: 0.0,
        };
        assert_eq!(frame_count(&fifteen), 450);
        assert_eq!(
            frame_count(&Window {
                lyric_start: 0.0,
                duration: 15.01,
                offset: 0.0
            }),
            451
        );
        assert_eq!(
            frame_count(&Window {
                lyric_start: 0.0,
                duration: 0.0,
                offset: 0.0
            }),
            1
        );
        assert_close(
            time_of_frame(
                45,
                &Window {
                    lyric_start: 2.0,
                    duration: 10.0,
                    offset: 0.0,
                },
            ),
            3.5,
        );
        assert_close(gain(0.0, 10.0), 0.0);
        assert_close(gain(0.15, 10.0), 0.5);
        assert_close(gain(5.0, 10.0), 1.0);
        assert_close(gain(9.55, 10.0), 0.5);
        assert_close(gain(10.0, 10.0), 0.0);
        assert_close(gain(-1.0, 10.0), 0.0);
        assert_close(gain(0.075, 10.0), 0.15625);
    }
}
