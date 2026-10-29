//! Where everything sits on a clip's canvas, for each format and template, and
//! the name a shared clip is saved under.
//!
//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/LyricShare/LyricShareLayout.swift`
//! and `LyricShareNaming`.

use super::motion::{RING_INNER, RING_LENGTH};
use super::style::{Format, Template};

/// The height of the footer mark.
pub const MARK_HEIGHT: f64 = 40.0;
/// The gap between the content and the footer mark.
pub const MARK_GAP: f64 = 28.0;
/// The size of the footer mark.
pub const MARK_SIZE: f64 = 28.0;
/// The height of the strip of bars along the bottom.
pub const STRIP_HEIGHT: f64 = 112.0;
/// The gap between the strip of bars and the lyrics above it.
pub const STRIP_GAP: f64 = 40.0;
/// The height of the slim waveform a poster draws.
pub const WAVE_HEIGHT: f64 = 56.0;
/// The gap between the waveform and the lyrics above it.
pub const WAVE_GAP: f64 = 32.0;
/// The gap between the header and the lyrics under it.
pub const HEADER_GAP: f64 = 48.0;
/// The height of a header block.
pub const HEADER_HEIGHT: f64 = 100.0;
/// The most a line of lyrics may shrink below the template's size to fit.
pub const MINIMUM_LYRIC_SCALE: f64 = 0.55;

/// The longest name, in characters, before the " (Lyrics)" suffix and extension.
pub const MAXIMUM_NAME_LENGTH: usize = 120;

/// A rectangle in canvas pixels, the origin at the top left.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    /// The right edge.
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }

    /// The bottom edge.
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }

    /// The horizontal centre.
    pub fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }

    /// The vertical centre.
    pub fn mid_y(&self) -> f64 {
        self.y + self.height / 2.0
    }
}

/// How a block of text lines up inside its rectangle.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Alignment {
    Leading,
    Center,
}

/// Where everything sits on a clip's canvas. `artwork` is the cover, or for
/// pulse the disc whether or not a cover is drawn on it; `visualizer` is the
/// strip of bars, or for pulse the square the ring fills. Mirrored in Rust as
/// `linux/shared/src/lyric_share/layout.rs`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Layout {
    pub width: f64,
    pub height: f64,
    pub artwork: Option<Rect>,
    pub artwork_radius: f64,
    pub header: Rect,
    pub header_alignment: Alignment,
    pub title_size: f64,
    pub artist_size: f64,
    pub lyrics: Rect,
    pub lyric_size: f64,
    pub lyric_alignment: Alignment,
    pub visualizer: Option<Rect>,
    pub mark: Rect,
    pub mark_size: f64,
}

impl Layout {
    /// The layout of a clip for a format and template, with the artwork and
    /// the visualizer drawn or left out.
    pub fn make(
        format: Format,
        template: Template,
        show_artwork: bool,
        show_visualizer: bool,
    ) -> Self {
        let safe = safe_area(format);
        let mark = Rect {
            x: safe.x,
            y: safe.max_y() - MARK_HEIGHT,
            width: safe.width,
            height: MARK_HEIGHT,
        };
        let content = Rect {
            x: safe.x,
            y: safe.y,
            width: safe.width,
            height: safe.height - MARK_HEIGHT - MARK_GAP,
        };
        let mut layout = Self {
            width: f64::from(format.pixel_width()),
            height: f64::from(format.pixel_height()),
            artwork: None,
            artwork_radius: 28.0,
            header: content,
            header_alignment: Alignment::Center,
            title_size: 44.0,
            artist_size: 34.0,
            lyrics: content,
            lyric_size: base_lyric_size(template, format),
            lyric_alignment: Alignment::Center,
            visualizer: None,
            mark,
            mark_size: MARK_SIZE,
        };
        if format == Format::Wide {
            layout_wide(
                &mut layout,
                content,
                template,
                show_artwork,
                show_visualizer,
            );
        } else {
            match template {
                Template::Spotlight | Template::Verse => layout_stack(
                    &mut layout,
                    content,
                    format,
                    template,
                    show_artwork,
                    show_visualizer,
                ),
                Template::Poster => {
                    layout_poster(&mut layout, content, show_artwork, show_visualizer)
                }
                Template::Pulse => layout_pulse(&mut layout, content, format, show_visualizer),
            }
        }
        if template == Template::Poster && !show_artwork {
            layout.lyric_size *= 1.25;
        }
        layout
    }
}

/// The part of the canvas content stays inside, clear of the buttons and
/// captions that apps lay over a post in each format.
pub fn safe_area(format: Format) -> Rect {
    match format {
        Format::Story => Rect {
            x: 84.0,
            y: 220.0,
            width: 912.0,
            height: 1420.0,
        },
        Format::Portrait => Rect {
            x: 84.0,
            y: 96.0,
            width: 912.0,
            height: 1158.0,
        },
        Format::Square => Rect {
            x: 80.0,
            y: 80.0,
            width: 920.0,
            height: 920.0,
        },
        Format::Wide => Rect {
            x: 120.0,
            y: 96.0,
            width: 1680.0,
            height: 888.0,
        },
    }
}

/// The lyric size a template starts from in a format, before the layout adjusts it.
pub fn base_lyric_size(template: Template, format: Format) -> f64 {
    let sizes = match template {
        Template::Spotlight => [88.0, 76.0, 68.0, 72.0],
        Template::Verse => [64.0, 58.0, 54.0, 56.0],
        Template::Poster => [54.0, 46.0, 42.0, 50.0],
        Template::Pulse => [64.0, 54.0, 48.0, 56.0],
    };
    let index = Format::ALL
        .iter()
        .position(|&candidate| candidate == format)
        .unwrap_or(0);
    sizes[index]
}

/// A header row with a small cover beside the title, the lyrics under it
/// and the bars along the bottom.
fn layout_stack(
    layout: &mut Layout,
    content: Rect,
    format: Format,
    template: Template,
    show_artwork: bool,
    show_visualizer: bool,
) {
    let mut bottom = content.max_y();
    if show_visualizer {
        layout.visualizer = Some(Rect {
            x: content.x,
            y: content.max_y() - STRIP_HEIGHT,
            width: content.width,
            height: STRIP_HEIGHT,
        });
        bottom -= STRIP_HEIGHT + STRIP_GAP;
    }
    if show_artwork {
        let thumb = if format == Format::Square {
            112.0
        } else {
            128.0
        };
        layout.artwork = Some(Rect {
            x: content.x,
            y: content.y,
            width: thumb,
            height: thumb,
        });
        layout.artwork_radius = 20.0;
        layout.header = Rect {
            x: content.x + thumb + 28.0,
            y: content.y,
            width: content.width - thumb - 28.0,
            height: thumb,
        };
    } else {
        layout.header = Rect {
            x: content.x,
            y: content.y,
            width: content.width,
            height: 96.0,
        };
    }
    layout.header_alignment = Alignment::Leading;
    layout.title_size = 40.0;
    layout.artist_size = 32.0;
    let top = layout.header.max_y() + HEADER_GAP;
    layout.lyrics = Rect {
        x: content.x,
        y: top,
        width: content.width,
        height: bottom - top,
    };
    layout.lyric_alignment = if template == Template::Spotlight {
        Alignment::Center
    } else {
        Alignment::Leading
    };
}

/// A large cover at the top, the title under it and the lyrics under
/// that, with a slim waveform at the foot.
fn layout_poster(layout: &mut Layout, content: Rect, show_artwork: bool, show_visualizer: bool) {
    let mut bottom = content.max_y();
    if show_visualizer {
        layout.visualizer = Some(Rect {
            x: content.x + content.width * 0.15,
            y: content.max_y() - WAVE_HEIGHT,
            width: content.width * 0.7,
            height: WAVE_HEIGHT,
        });
        bottom -= WAVE_HEIGHT + WAVE_GAP;
    }
    if show_artwork {
        let side = content.width.min((bottom - content.y) * 0.46).round();
        let artwork = Rect {
            x: content.mid_x() - side / 2.0,
            y: content.y,
            width: side,
            height: side,
        };
        layout.artwork = Some(artwork);
        layout.header = Rect {
            x: content.x,
            y: artwork.max_y() + 36.0,
            width: content.width,
            height: HEADER_HEIGHT,
        };
    } else {
        layout.header = Rect {
            x: content.x,
            y: content.y,
            width: content.width,
            height: HEADER_HEIGHT,
        };
    }
    let top = layout.header.max_y() + 36.0;
    layout.lyrics = Rect {
        x: content.x,
        y: top,
        width: content.width,
        height: bottom - top,
    };
}

/// The title at the top, the disc and its ring under it, the line below.
fn layout_pulse(layout: &mut Layout, content: Rect, format: Format, show_visualizer: bool) {
    layout.header = Rect {
        x: content.x,
        y: content.y,
        width: content.width,
        height: HEADER_HEIGHT,
    };
    let factor = if format == Format::Story { 0.25 } else { 0.19 };
    let radius = (content.width.min(content.height) * factor).round();
    let ring = radius * (RING_INNER + RING_LENGTH);
    let centre_y = layout.header.max_y() + 56.0 + ring;
    place_disc(layout, content.mid_x(), centre_y, radius, show_visualizer);
    let top = centre_y + ring + 40.0;
    layout.lyrics = Rect {
        x: content.x,
        y: top,
        width: content.width,
        height: content.max_y() - top,
    };
}

/// Landscape: the cover or the disc on the left, the words on the right.
fn layout_wide(
    layout: &mut Layout,
    content: Rect,
    template: Template,
    show_artwork: bool,
    show_visualizer: bool,
) {
    let left = Rect {
        x: content.x,
        y: content.y,
        width: 640.0,
        height: content.height,
    };
    let right = Rect {
        x: content.x + 640.0 + 96.0,
        y: content.y,
        width: content.width - 736.0,
        height: content.height,
    };
    if template == Template::Pulse {
        let radius =
            ((left.width.min(left.height) / 2.0) / (RING_INNER + RING_LENGTH) * 0.96).round();
        place_disc(layout, left.mid_x(), left.mid_y(), radius, show_visualizer);
        layout.header = Rect {
            x: right.x,
            y: right.y,
            width: right.width,
            height: HEADER_HEIGHT,
        };
        layout.header_alignment = Alignment::Leading;
        let top = layout.header.max_y() + HEADER_GAP;
        layout.lyrics = Rect {
            x: right.x,
            y: top,
            width: right.width,
            height: right.max_y() - top,
        };
        layout.lyric_alignment = Alignment::Leading;
        return;
    }
    let mut text = if show_artwork {
        let side = left.width.min(left.height - 136.0);
        let artwork = Rect {
            x: left.x,
            y: left.y + (left.height - side - 136.0) / 2.0,
            width: side,
            height: side,
        };
        layout.artwork = Some(artwork);
        layout.header = Rect {
            x: left.x,
            y: artwork.max_y() + 36.0,
            width: left.width,
            height: HEADER_HEIGHT,
        };
        layout.header_alignment = Alignment::Center;
        right
    } else {
        layout.header = Rect {
            x: content.x,
            y: content.y,
            width: content.width,
            height: HEADER_HEIGHT,
        };
        layout.header_alignment = Alignment::Leading;
        let top = layout.header.max_y() + HEADER_GAP;
        Rect {
            x: content.x,
            y: top,
            width: content.width,
            height: content.max_y() - top,
        }
    };
    if show_visualizer {
        if template == Template::Poster {
            layout.visualizer = Some(Rect {
                x: text.x + text.width * 0.15,
                y: text.max_y() - WAVE_HEIGHT,
                width: text.width * 0.7,
                height: WAVE_HEIGHT,
            });
            text.height -= WAVE_HEIGHT + WAVE_GAP;
        } else {
            layout.visualizer = Some(Rect {
                x: text.x,
                y: text.max_y() - STRIP_HEIGHT,
                width: text.width,
                height: STRIP_HEIGHT,
            });
            text.height -= STRIP_HEIGHT + STRIP_GAP;
        }
    }
    layout.lyrics = text;
    layout.lyric_alignment = if template == Template::Spotlight {
        Alignment::Center
    } else {
        Alignment::Leading
    };
}

/// Puts the disc at a centre with its ring, when a visualizer is drawn.
fn place_disc(
    layout: &mut Layout,
    centre_x: f64,
    centre_y: f64,
    radius: f64,
    show_visualizer: bool,
) {
    layout.artwork = Some(Rect {
        x: centre_x - radius,
        y: centre_y - radius,
        width: radius * 2.0,
        height: radius * 2.0,
    });
    layout.artwork_radius = radius;
    if show_visualizer {
        let ring = radius * (RING_INNER + RING_LENGTH);
        layout.visualizer = Some(Rect {
            x: centre_x - ring,
            y: centre_y - ring,
            width: ring * 2.0,
            height: ring * 2.0,
        });
    }
}

/// "Artist – Title (Lyrics).ext", with the characters no file system
/// accepts and control characters dropped, runs of spaces collapsed and
/// the name before " (Lyrics)" cut to `MAXIMUM_NAME_LENGTH` characters.
pub fn file_name(title: &str, artist: &str, extension: &str) -> String {
    let clean_title = clean(title);
    let clean_artist = clean(artist);
    let mut stem = match (clean_artist.is_empty(), clean_title.is_empty()) {
        (false, false) => format!("{clean_artist} \u{2013} {clean_title}"),
        (true, false) => clean_title,
        (false, true) => clean_artist,
        (true, true) => "Flaccy".to_string(),
    };
    if stem.chars().count() > MAXIMUM_NAME_LENGTH {
        let cut: String = stem.chars().take(MAXIMUM_NAME_LENGTH).collect();
        stem = cut.trim_end().to_string();
    }
    format!("{stem} (Lyrics).{extension}")
}

/// Characters no file system accepts in a name.
const FORBIDDEN: [char; 9] = ['/', '\\', ':', '*', '?', '"', '<', '>', '|'];

/// Drops forbidden and control characters and collapses whitespace runs into
/// one space between words.
fn clean(text: &str) -> String {
    let mut out = String::new();
    let mut pending_space = false;
    for character in text.chars() {
        if character.is_whitespace() {
            pending_space = !out.is_empty();
            continue;
        }
        if FORBIDDEN.contains(&character) || character.is_control() {
            continue;
        }
        if pending_space {
            out.push(' ');
            pending_space = false;
        }
        out.push(character);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_close(actual: f64, expected: f64) {
        assert!((actual - expected).abs() < 1e-9, "{actual} != {expected}");
    }

    #[test]
    fn story_layouts() {
        let spotlight = Layout::make(Format::Story, Template::Spotlight, true, true);
        assert_eq!(spotlight.width, 1080.0);
        assert_eq!(spotlight.height, 1920.0);
        assert_eq!(
            spotlight.mark,
            Rect {
                x: 84.0,
                y: 1600.0,
                width: 912.0,
                height: 40.0
            }
        );
        assert_eq!(
            spotlight.artwork,
            Some(Rect {
                x: 84.0,
                y: 220.0,
                width: 128.0,
                height: 128.0
            })
        );
        assert_eq!(
            spotlight.header,
            Rect {
                x: 240.0,
                y: 220.0,
                width: 756.0,
                height: 128.0
            }
        );
        assert_eq!(
            spotlight.visualizer,
            Some(Rect {
                x: 84.0,
                y: 1460.0,
                width: 912.0,
                height: 112.0
            })
        );
        assert_eq!(
            spotlight.lyrics,
            Rect {
                x: 84.0,
                y: 396.0,
                width: 912.0,
                height: 1024.0
            }
        );
        assert_eq!(spotlight.lyric_size, 88.0);
        assert_eq!(spotlight.lyric_alignment, Alignment::Center);
        assert_eq!(spotlight.header_alignment, Alignment::Leading);

        let verse = Layout::make(Format::Story, Template::Verse, false, false);
        assert_eq!(verse.artwork, None);
        assert_eq!(verse.visualizer, None);
        assert_eq!(
            verse.header,
            Rect {
                x: 84.0,
                y: 220.0,
                width: 912.0,
                height: 96.0
            }
        );
        assert_eq!(
            verse.lyrics,
            Rect {
                x: 84.0,
                y: 364.0,
                width: 912.0,
                height: 1208.0
            }
        );
        assert_eq!(verse.lyric_alignment, Alignment::Leading);

        let poster = Layout::make(Format::Story, Template::Poster, true, true);
        assert_eq!(
            poster.visualizer,
            Some(Rect {
                x: 84.0 + 912.0 * 0.15,
                y: 1516.0,
                width: 912.0 * 0.7,
                height: 56.0,
            })
        );
        assert_eq!(
            poster.artwork,
            Some(Rect {
                x: 249.5,
                y: 220.0,
                width: 581.0,
                height: 581.0
            })
        );
        assert_eq!(
            poster.header,
            Rect {
                x: 84.0,
                y: 837.0,
                width: 912.0,
                height: 100.0
            }
        );
        assert_eq!(
            poster.lyrics,
            Rect {
                x: 84.0,
                y: 973.0,
                width: 912.0,
                height: 511.0
            }
        );
        assert_eq!(poster.lyric_size, 54.0);
        assert_eq!(
            Layout::make(Format::Story, Template::Poster, false, true).lyric_size,
            67.5
        );

        let pulse = Layout::make(Format::Story, Template::Pulse, true, true);
        assert_eq!(
            pulse.artwork,
            Some(Rect {
                x: 312.0,
                y: 471.76,
                width: 456.0,
                height: 456.0
            })
        );
        assert_eq!(pulse.artwork_radius, 228.0);
        let ring = 228.0 * 1.42;
        assert_close(pulse.visualizer.map_or(0.0, |rect| rect.width), ring * 2.0);
        assert_close(pulse.lyrics.y, 376.0 + ring * 2.0 + 40.0);
        assert_close(pulse.lyrics.max_y(), 1572.0);
    }

    #[test]
    fn square_and_wide_layouts() {
        let pulse = Layout::make(Format::Square, Template::Pulse, false, false);
        assert_eq!(pulse.artwork_radius, 162.0);
        assert!(pulse.artwork.is_some());
        assert_eq!(pulse.visualizer, None);
        assert_eq!(pulse.lyric_size, 48.0);

        let square = Layout::make(Format::Square, Template::Spotlight, true, true);
        assert_eq!(square.artwork.map(|rect| rect.width), Some(112.0));
        assert_eq!(square.lyric_size, 68.0);

        let wide = Layout::make(Format::Wide, Template::Verse, true, true);
        assert_eq!(
            wide.artwork,
            Some(Rect {
                x: 120.0,
                y: 118.0,
                width: 640.0,
                height: 640.0
            })
        );
        assert_eq!(
            wide.header,
            Rect {
                x: 120.0,
                y: 794.0,
                width: 640.0,
                height: 100.0
            }
        );
        assert_eq!(
            wide.visualizer,
            Some(Rect {
                x: 856.0,
                y: 804.0,
                width: 944.0,
                height: 112.0
            })
        );
        assert_eq!(
            wide.lyrics,
            Rect {
                x: 856.0,
                y: 96.0,
                width: 944.0,
                height: 668.0
            }
        );
        assert_eq!(wide.lyric_alignment, Alignment::Leading);

        let wide_pulse = Layout::make(Format::Wide, Template::Pulse, true, true);
        assert_eq!(wide_pulse.artwork_radius, 216.0);
        assert_close(wide_pulse.artwork.map_or(0.0, |rect| rect.mid_x()), 440.0);
        assert_close(wide_pulse.artwork.map_or(0.0, |rect| rect.mid_y()), 506.0);
        assert_eq!(
            wide_pulse.header,
            Rect {
                x: 856.0,
                y: 96.0,
                width: 944.0,
                height: 100.0
            }
        );

        let bare = Layout::make(Format::Wide, Template::Poster, false, true);
        assert_eq!(bare.artwork, None);
        assert_eq!(
            bare.header,
            Rect {
                x: 120.0,
                y: 96.0,
                width: 1680.0,
                height: 100.0
            }
        );
        assert_eq!(
            bare.visualizer,
            Some(Rect {
                x: 120.0 + 1680.0 * 0.15,
                y: 860.0,
                width: 1680.0 * 0.7,
                height: 56.0,
            })
        );
        assert_eq!(
            bare.lyrics,
            Rect {
                x: 120.0,
                y: 244.0,
                width: 1680.0,
                height: 584.0
            }
        );
        assert_eq!(bare.lyric_size, 62.5);
    }

    #[test]
    fn file_names() {
        assert_eq!(
            file_name("Hold On / Let Go?", "  The   Band: ", "mp4"),
            "The Band \u{2013} Hold On Let Go (Lyrics).mp4"
        );
        assert_eq!(file_name("Tab\tSong", "", "png"), "Tab Song (Lyrics).png");
        assert_eq!(file_name("", "", "png"), "Flaccy (Lyrics).png");
        let long = file_name(&"a".repeat(200), "B", "mp4");
        assert_eq!(long.chars().count(), 133);
        assert!(long.ends_with("a (Lyrics).mp4"));
    }
}
