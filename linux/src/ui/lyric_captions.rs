use crate::ui::lyric_line::{Look, LyricLine};
use flaccy_shared::lyrics::{Document, LineProgress, INTERLUDE_BEATS};
use gtk::prelude::*;
use std::cell::{Cell, RefCell};

/// The line after the sung one is set this much smaller.
const NEXT_SCALE: f64 = 0.72;

/// What the sung line's slot holds.
enum Sung {
    Text(LyricLine),
    Beats(Vec<gtk::Label>),
}

/// Lyrics as captions across the foot of a music video: the line being sung,
/// large and centred, filling word by word, with the next line under it.
/// Only the two lines on screen exist as widgets; they are replaced when the
/// sung line changes.
pub struct CaptionStrip {
    pub widget: gtk::Box,
    lines: gtk::Box,
    shown: Cell<Option<Option<usize>>>,
    sung: RefCell<Option<Sung>>,
    scale: Cell<f64>,
}

impl CaptionStrip {
    pub fn new() -> Self {
        let lines = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(6)
            .valign(gtk::Align::End)
            .hexpand(true)
            .build();
        lines.add_css_class("lyric-caption");
        let widget = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .valign(gtk::Align::Fill)
            .vexpand(true)
            .margin_start(24)
            .margin_end(24)
            .build();
        let spacer = gtk::Box::new(gtk::Orientation::Vertical, 0);
        spacer.set_vexpand(true);
        widget.append(&spacer);
        widget.append(&lines);
        widget.set_can_target(false);
        Self {
            widget,
            lines,
            shown: Cell::new(None),
            sung: RefCell::new(None),
            scale: Cell::new(1.0),
        }
    }

    /// Sets how large the captions are and how far above the strip's foot
    /// they sit.
    pub fn set_layout(&self, scale: f64, margin: f64) {
        self.lines.set_margin_bottom(margin.round().max(0.0) as i32);
        if (self.scale.replace(scale) - scale).abs() < 1e-3 {
            return;
        }
        let mut child = self.lines.first_child();
        while let Some(widget) = child {
            if let Some(line) = widget.downcast_ref::<LyricLine>() {
                line.set_look(look(scale, widget.has_css_class("lyric-caption-next")));
            }
            child = widget.next_sibling();
        }
    }

    /// Forgets the lines on screen, for new lyrics or a new place to show them.
    pub fn reset(&self) {
        self.shown.set(None);
        self.sung.borrow_mut().take();
        while let Some(child) = self.lines.first_child() {
            self.lines.remove(&child);
        }
    }

    /// Shows the line being sung at `time` and the next one, and moves the
    /// fill inside the sung line. Returns whether a word is mid-fill.
    pub fn follow(&self, document: &Document, primary: Option<usize>, time: f64) -> bool {
        if self.shown.get() != Some(primary) {
            self.rebuild(document, primary);
            self.shown.set(Some(primary));
        }
        let Some(line) = primary.and_then(|index| document.lines.get(index)) else {
            return false;
        };
        match self.sung.borrow().as_ref() {
            Some(Sung::Text(text)) => {
                let progress = line.progress(time);
                text.set_progress(progress);
                matches!(progress, Some(LineProgress::Singing { .. }))
            }
            Some(Sung::Beats(beats)) => {
                let lit = line.lit_beats(time);
                for (index, beat) in beats.iter().enumerate() {
                    if index < lit {
                        beat.add_css_class("lyric-beat-lit");
                    } else {
                        beat.remove_css_class("lyric-beat-lit");
                    }
                }
                false
            }
            None => false,
        }
    }

    fn rebuild(&self, document: &Document, primary: Option<usize>) {
        self.reset();
        let scale = self.scale.get();
        if let Some(line) = primary.and_then(|index| document.lines.get(index)) {
            if line.is_interlude() {
                let row = gtk::Box::builder()
                    .orientation(gtk::Orientation::Horizontal)
                    .spacing(18)
                    .halign(gtk::Align::Center)
                    .build();
                row.add_css_class("lyric-caption-line");
                let beats: Vec<gtk::Label> = (0..INTERLUDE_BEATS)
                    .map(|_| {
                        let beat = gtk::Label::new(Some("\u{25CF}"));
                        beat.add_css_class("lyric-beat");
                        row.append(&beat);
                        beat
                    })
                    .collect();
                self.lines.append(&row);
                *self.sung.borrow_mut() = Some(Sung::Beats(beats));
            } else {
                let text = LyricLine::new(&line.text, &line.words);
                text.set_look(look(scale, false));
                text.add_css_class("lyric-caption-line");
                if line.has_words() {
                    text.add_css_class("lyric-caption-sung");
                }
                if line.background {
                    text.add_css_class("lyric-line-backing");
                }
                self.lines.append(&text);
                *self.sung.borrow_mut() = Some(Sung::Text(text));
            }
        }
        if let Some(next) = next_sung_line(document, primary) {
            let line = &document.lines[next];
            let text = LyricLine::new(&line.text, &[]);
            text.set_look(look(scale, true));
            text.add_css_class("lyric-caption-next");
            self.lines.append(&text);
        }
    }
}

/// How a caption line is set: centred, and the next line smaller.
fn look(scale: f64, next: bool) -> Look {
    Look {
        centered: true,
        scale: if next { scale * NEXT_SCALE } else { scale },
    }
}

/// The next line with words after `primary`, past any instrumental break; the
/// first one before anything has been sung.
pub fn next_sung_line(document: &Document, primary: Option<usize>) -> Option<usize> {
    let from = primary.map_or(0, |index| index + 1);
    (from..document.lines.len()).find(|index| !document.lines[*index].is_interlude())
}

#[cfg(test)]
mod tests {
    use super::next_sung_line;
    use flaccy_shared::lyrics::parse_lrc;

    #[test]
    fn the_next_line_skips_an_instrumental_break() {
        let document = parse_lrc("[00:01.00]one\n[00:03.00]two\n[00:30.00]three");
        let two = document
            .lines
            .iter()
            .position(|line| line.text == "two")
            .unwrap();
        let three = document
            .lines
            .iter()
            .position(|line| line.text == "three")
            .unwrap();
        assert!(document.lines[two + 1].is_interlude());
        assert_eq!(next_sung_line(&document, Some(two)), Some(three));
    }

    #[test]
    fn before_anything_is_sung_the_first_line_is_next() {
        let document = parse_lrc("[00:05.00]one\n[00:07.00]two");
        let one = document.lines.iter().position(|line| line.text == "one");
        assert_eq!(next_sung_line(&document, None), one);
    }

    #[test]
    fn the_last_line_has_nothing_after_it() {
        let document = parse_lrc("[00:05.00]one\n[00:07.00]two");
        assert_eq!(
            next_sung_line(&document, Some(document.lines.len() - 1)),
            None
        );
    }
}
