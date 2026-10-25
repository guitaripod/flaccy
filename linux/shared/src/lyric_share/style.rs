//! The look of a lyric clip apart from which lines it holds: how it moves, its
//! canvas, colours, typeface and which pieces are drawn.
//!
//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/LyricShare/LyricShareStyle.swift`
//! and reads and writes the same `key=value;` line, so a clip's look saved by one
//! client opens on the others.

/// How a lyric clip moves: one line at a time, the verse scrolling past, a
/// poster that lights line by line, or a disc that breathes with the music.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Template {
    Spotlight,
    Verse,
    Poster,
    Pulse,
}

impl Template {
    /// Every template, in declaration order.
    pub const ALL: [Self; 4] = [Self::Spotlight, Self::Verse, Self::Poster, Self::Pulse];

    /// The key this template is written under in an encoded style.
    pub fn key(self) -> &'static str {
        match self {
            Self::Spotlight => "spotlight",
            Self::Verse => "verse",
            Self::Poster => "poster",
            Self::Pulse => "pulse",
        }
    }

    /// The template an encoded key names, or `None` when none does.
    pub fn from_key(key: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|template| template.key() == key)
    }
}

/// The canvas a clip is made for, named after where people post it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Story,
    Portrait,
    Square,
    Wide,
}

impl Format {
    /// Every format, in declaration order.
    pub const ALL: [Self; 4] = [Self::Story, Self::Portrait, Self::Square, Self::Wide];

    /// The canvas width in pixels.
    pub fn pixel_width(self) -> u32 {
        if self == Self::Wide {
            1920
        } else {
            1080
        }
    }

    /// The canvas height in pixels.
    pub fn pixel_height(self) -> u32 {
        match self {
            Self::Story => 1920,
            Self::Portrait => 1350,
            Self::Square | Self::Wide => 1080,
        }
    }

    /// The key this format is written under in an encoded style.
    pub fn key(self) -> &'static str {
        match self {
            Self::Story => "story",
            Self::Portrait => "portrait",
            Self::Square => "square",
            Self::Wide => "wide",
        }
    }

    /// The format an encoded key names, or `None` when none does.
    pub fn from_key(key: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|format| format.key() == key)
    }
}

/// Where a clip's colours come from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Theme {
    Artwork,
    Vivid,
    Dark,
    Light,
}

impl Theme {
    /// Every theme, in declaration order.
    pub const ALL: [Self; 4] = [Self::Artwork, Self::Vivid, Self::Dark, Self::Light];

    /// The key this theme is written under in an encoded style.
    pub fn key(self) -> &'static str {
        match self {
            Self::Artwork => "artwork",
            Self::Vivid => "vivid",
            Self::Dark => "dark",
            Self::Light => "light",
        }
    }

    /// The theme an encoded key names, or `None` when none does.
    pub fn from_key(key: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|theme| theme.key() == key)
    }
}

/// The family the lyrics are set in. Each client maps it onto its own fonts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Typeface {
    Modern,
    Serif,
    Rounded,
    Mono,
}

impl Typeface {
    /// Every typeface, in declaration order.
    pub const ALL: [Self; 4] = [Self::Modern, Self::Serif, Self::Rounded, Self::Mono];

    /// The key this typeface is written under in an encoded style.
    pub fn key(self) -> &'static str {
        match self {
            Self::Modern => "modern",
            Self::Serif => "serif",
            Self::Rounded => "rounded",
            Self::Mono => "mono",
        }
    }

    /// The typeface an encoded key names, or `None` when none does.
    pub fn from_key(key: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|typeface| typeface.key() == key)
    }
}

/// Every choice a person makes about a lyric clip apart from which lines it
/// holds. Mirrored in Rust as `linux/shared/src/lyric_share/style.rs`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Style {
    pub template: Template,
    pub format: Format,
    pub theme: Theme,
    pub typeface: Typeface,
    pub show_artwork: bool,
    pub show_visualizer: bool,
    pub show_mark: bool,
}

impl Default for Style {
    fn default() -> Self {
        Self {
            template: Template::Spotlight,
            format: Format::Story,
            theme: Theme::Artwork,
            typeface: Typeface::Modern,
            show_artwork: true,
            show_visualizer: true,
            show_mark: true,
        }
    }
}

impl Style {
    /// The style as one line of `key=value` pairs, the form every client
    /// remembers the last clip's look in.
    pub fn encode(&self) -> String {
        [
            format!("template={}", self.template.key()),
            format!("format={}", self.format.key()),
            format!("theme={}", self.theme.key()),
            format!("typeface={}", self.typeface.key()),
            format!("artwork={}", u8::from(self.show_artwork)),
            format!("visualizer={}", u8::from(self.show_visualizer)),
            format!("mark={}", u8::from(self.show_mark)),
        ]
        .join(";")
    }

    /// Reads what `encode` wrote. Anything unknown or malformed keeps the
    /// standard value, so a style saved by a newer build still opens.
    pub fn decode(encoded: &str) -> Self {
        let mut style = Self::default();
        for pair in encoded.split(';') {
            let Some((key, value)) = pair.split_once('=') else {
                continue;
            };
            match key {
                "template" => style.template = Template::from_key(value).unwrap_or(style.template),
                "format" => style.format = Format::from_key(value).unwrap_or(style.format),
                "theme" => style.theme = Theme::from_key(value).unwrap_or(style.theme),
                "typeface" => style.typeface = Typeface::from_key(value).unwrap_or(style.typeface),
                "artwork" => style.show_artwork = parse_flag(value).unwrap_or(style.show_artwork),
                "visualizer" => {
                    style.show_visualizer = parse_flag(value).unwrap_or(style.show_visualizer)
                }
                "mark" => style.show_mark = parse_flag(value).unwrap_or(style.show_mark),
                _ => {}
            }
        }
        style
    }
}

/// Reads a `1` or `0` flag, or `None` for anything else.
fn parse_flag(value: &str) -> Option<bool> {
    match value {
        "1" => Some(true),
        "0" => Some(false),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_style_round_trips_and_tolerates_unknown_values() {
        let style = Style {
            template: Template::Pulse,
            format: Format::Wide,
            theme: Theme::Light,
            typeface: Typeface::Mono,
            show_artwork: false,
            show_visualizer: true,
            show_mark: false,
        };
        assert_eq!(
            style.encode(),
            "template=pulse;format=wide;theme=light;typeface=mono;artwork=0;visualizer=1;mark=0"
        );
        assert_eq!(Style::decode(&style.encode()), style);
        let odd = Style::decode("template=hologram;format=square;artwork=yes;bogus;mark=0;=1");
        assert_eq!(odd.template, Template::Spotlight);
        assert_eq!(odd.format, Format::Square);
        assert!(odd.show_artwork);
        assert!(!odd.show_mark);
        assert_eq!(Style::decode(""), Style::default());
    }

    #[test]
    fn formats_have_their_pixel_sizes() {
        assert_eq!(Format::Story.pixel_width(), 1080);
        assert_eq!(Format::Story.pixel_height(), 1920);
        assert_eq!(Format::Portrait.pixel_height(), 1350);
        assert_eq!(Format::Square.pixel_height(), 1080);
        assert_eq!(Format::Wide.pixel_width(), 1920);
        assert_eq!(Format::Wide.pixel_height(), 1080);
    }
}
