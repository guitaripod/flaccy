use super::color::{parse_hex, Rgb};
use std::cell::RefCell;
use std::path::PathBuf;

/// The newest `format` this build reads. A theme written for a later one is
/// refused by name instead of being half applied.
pub const FORMAT: i64 = 1;

pub const COVER_SIZE_MIN: i32 = 96;
pub const COVER_SIZE_MAX: i32 = 320;
pub const COVER_SIZE_DEFAULT: i32 = 140;

pub const CORNERS_SHARP: f64 = 0.0;
pub const CORNERS_STANDARD: f64 = 1.0;
pub const CORNERS_ROUND: f64 = 1.6;
pub const CORNERS_MAX: f64 = 2.0;

/// Whether a theme or one of its color schemes is drawn for one mode only.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Appearance {
    Any,
    Dark,
    Light,
}

/// How the Albums page lays the library out.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AlbumsView {
    Grid,
    Wall,
    List,
    Carousel,
}

impl AlbumsView {
    pub const ALL: [AlbumsView; 4] = [
        AlbumsView::Grid,
        AlbumsView::Wall,
        AlbumsView::List,
        AlbumsView::Carousel,
    ];

    pub fn id(self) -> &'static str {
        match self {
            AlbumsView::Grid => "grid",
            AlbumsView::Wall => "wall",
            AlbumsView::List => "list",
            AlbumsView::Carousel => "carousel",
        }
    }

    pub fn from_id(id: &str) -> Option<AlbumsView> {
        Self::ALL.into_iter().find(|view| view.id() == id)
    }

    pub fn title(self) -> &'static str {
        match self {
            AlbumsView::Grid => "Grid",
            AlbumsView::Wall => "Wall",
            AlbumsView::List => "List",
            AlbumsView::Carousel => "Carousel",
        }
    }

    pub fn icon(self) -> &'static str {
        match self {
            AlbumsView::Grid => "flaccy-view-grid-symbolic",
            AlbumsView::Wall => "flaccy-view-wall-symbolic",
            AlbumsView::List => "flaccy-view-list-symbolic",
            AlbumsView::Carousel => "flaccy-view-carousel-symbolic",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum CoverShape {
    Rounded,
    Square,
    Circle,
}

impl CoverShape {
    pub const ALL: [CoverShape; 3] = [CoverShape::Rounded, CoverShape::Square, CoverShape::Circle];

    pub fn id(self) -> &'static str {
        match self {
            CoverShape::Rounded => "rounded",
            CoverShape::Square => "square",
            CoverShape::Circle => "circle",
        }
    }

    pub fn from_id(id: &str) -> Option<CoverShape> {
        Self::ALL.into_iter().find(|shape| shape.id() == id)
    }

    pub fn title(self) -> &'static str {
        match self {
            CoverShape::Rounded => "Rounded",
            CoverShape::Square => "Square",
            CoverShape::Circle => "Circle",
        }
    }
}

/// One layer of look: what a theme, a variant or the person's own choices set.
/// Anything left `None` falls through to the layer beneath.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Style {
    pub interface_font: Option<String>,
    pub heading_font: Option<String>,
    pub corners: Option<f64>,
    pub covers: Option<CoverShape>,
    pub shadows: Option<bool>,
    pub albums: Option<AlbumsView>,
    pub cover_size: Option<i32>,
    pub glow: Option<bool>,
}

impl Style {
    /// This layer laid over `base`: what this one sets wins.
    pub fn over(&self, base: &Style) -> Style {
        Style {
            interface_font: self
                .interface_font
                .clone()
                .or_else(|| base.interface_font.clone()),
            heading_font: self
                .heading_font
                .clone()
                .or_else(|| base.heading_font.clone()),
            corners: self.corners.or(base.corners),
            covers: self.covers.or(base.covers),
            shadows: self.shadows.or(base.shadows),
            albums: self.albums.or(base.albums),
            cover_size: self.cover_size.or(base.cover_size),
            glow: self.glow.or(base.glow),
        }
    }

    pub fn is_empty(&self) -> bool {
        *self == Style::default()
    }
}

/// Exact colors for one mode. Whatever is left out is worked out from the
/// scheme's accent.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Colors {
    pub window: Option<Rgb>,
    pub view: Option<Rgb>,
    pub sidebar: Option<Rgb>,
    pub headerbar: Option<Rgb>,
    pub card: Option<Rgb>,
    pub popover: Option<Rgb>,
    pub text: Option<Rgb>,
    pub accent: Option<Rgb>,
    pub accent_text: Option<Rgb>,
    pub on_accent: Option<Rgb>,
    pub wash_a: Option<Rgb>,
    pub wash_b: Option<Rgb>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Accent {
    /// Follows the cover of the album that is playing.
    Artwork,
    Fixed(Rgb),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Scheme {
    pub id: String,
    pub name: String,
    pub accent: Accent,
    pub muted: bool,
    pub appearance: Option<Appearance>,
    pub dark: Colors,
    pub light: Colors,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Variant {
    pub id: String,
    pub name: String,
    pub style: Style,
}

/// A theme as its folder describes it: `theme.toml`, with `style.css` beside
/// it when the theme restyles more than the document can say.
#[derive(Clone, Debug, PartialEq)]
pub struct Pack {
    pub id: String,
    pub name: String,
    pub author: String,
    pub description: String,
    pub appearance: Appearance,
    pub style: Style,
    pub schemes: Vec<Scheme>,
    pub variants: Vec<Variant>,
    pub css: Option<String>,
    pub dir: Option<PathBuf>,
    pub builtin: bool,
    pub warnings: Vec<String>,
}

const APPEARANCES: [(&str, Appearance); 3] = [
    ("any", Appearance::Any),
    ("dark", Appearance::Dark),
    ("light", Appearance::Light),
];

const VIEWS: [(&str, AlbumsView); 4] = [
    ("grid", AlbumsView::Grid),
    ("wall", AlbumsView::Wall),
    ("list", AlbumsView::List),
    ("carousel", AlbumsView::Carousel),
];

const SHAPES: [(&str, CoverShape); 3] = [
    ("rounded", CoverShape::Rounded),
    ("square", CoverShape::Square),
    ("circle", CoverShape::Circle),
];

const CORNER_NAMES: [(&str, f64); 3] = [
    ("sharp", CORNERS_SHARP),
    ("standard", CORNERS_STANDARD),
    ("round", CORNERS_ROUND),
];

/// Reads one table of a theme document, noting every key it cannot use and
/// every key nobody asked for, so a typo is named instead of silently ignored.
struct Reader<'a> {
    table: &'a toml::Table,
    path: String,
    asked: RefCell<Vec<&'static str>>,
    notes: &'a RefCell<Vec<String>>,
}

impl<'a> Reader<'a> {
    fn root(table: &'a toml::Table, notes: &'a RefCell<Vec<String>>) -> Reader<'a> {
        Reader {
            table,
            path: String::new(),
            asked: RefCell::new(Vec::new()),
            notes,
        }
    }

    fn named(&self, key: &str) -> String {
        if self.path.is_empty() {
            key.to_string()
        } else {
            format!("{}.{key}", self.path)
        }
    }

    fn note(&self, text: String) {
        self.notes.borrow_mut().push(text);
    }

    fn value(&self, key: &'static str) -> Option<&'a toml::Value> {
        self.asked.borrow_mut().push(key);
        self.table.get(key)
    }

    fn text(&self, key: &'static str) -> Option<String> {
        match self.value(key)? {
            toml::Value::String(text) if !text.trim().is_empty() => Some(text.trim().to_string()),
            toml::Value::String(_) => None,
            _ => {
                self.note(format!("{} must be text in quotes", self.named(key)));
                None
            }
        }
    }

    fn flag(&self, key: &'static str) -> Option<bool> {
        match self.value(key)? {
            toml::Value::Boolean(flag) => Some(*flag),
            _ => {
                self.note(format!("{} must be true or false", self.named(key)));
                None
            }
        }
    }

    fn number(&self, key: &'static str) -> Option<f64> {
        match self.value(key)? {
            toml::Value::Integer(number) => Some(*number as f64),
            toml::Value::Float(number) if number.is_finite() => Some(*number),
            _ => {
                self.note(format!("{} must be a number", self.named(key)));
                None
            }
        }
    }

    fn color(&self, key: &'static str) -> Option<Rgb> {
        let text = self.text(key)?;
        let color = parse_hex(&text);
        if color.is_none() {
            self.note(format!(
                "{}: \"{text}\" is not a color (write it as #rrggbb)",
                self.named(key)
            ));
        }
        color
    }

    fn choice<T: Copy>(&self, key: &'static str, options: &[(&str, T)]) -> Option<T> {
        let text = self.text(key)?;
        let found = options
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case(&text))
            .map(|(_, value)| *value);
        if found.is_none() {
            let names: Vec<&str> = options.iter().map(|(name, _)| *name).collect();
            self.note(format!(
                "{}: \"{text}\" is not one of {}",
                self.named(key),
                names.join(", ")
            ));
        }
        found
    }

    fn table(&self, key: &'static str) -> Option<Reader<'a>> {
        match self.value(key)? {
            toml::Value::Table(table) => Some(Reader {
                table,
                path: self.named(key),
                asked: RefCell::new(Vec::new()),
                notes: self.notes,
            }),
            _ => {
                self.note(format!(
                    "{} must be a [{}] table",
                    self.named(key),
                    self.named(key)
                ));
                None
            }
        }
    }

    fn tables(&self, key: &'static str) -> Vec<Reader<'a>> {
        match self.value(key) {
            None => Vec::new(),
            Some(toml::Value::Array(items)) => items
                .iter()
                .enumerate()
                .filter_map(|(index, item)| match item {
                    toml::Value::Table(table) => Some(Reader {
                        table,
                        path: format!("{} {}", self.named(key), index + 1),
                        asked: RefCell::new(Vec::new()),
                        notes: self.notes,
                    }),
                    _ => None,
                })
                .collect(),
            Some(_) => {
                self.note(format!(
                    "{} must be written as [[{}]] blocks",
                    self.named(key),
                    self.named(key)
                ));
                Vec::new()
            }
        }
    }

    /// Names every key of this table that nothing read.
    fn finish(self) {
        let asked = self.asked.borrow();
        for key in self.table.keys() {
            if !asked.iter().any(|known| known == key) {
                self.note(format!(
                    "{} is not something a theme can set",
                    self.named(key)
                ));
            }
        }
    }
}

fn read_corners(shape: &Reader) -> Option<f64> {
    shape.asked.borrow_mut().push("corners");
    match shape.table.get("corners")? {
        toml::Value::String(_) => shape.choice("corners", &CORNER_NAMES),
        toml::Value::Integer(_) | toml::Value::Float(_) => {
            let scale = shape.number("corners")?;
            if !(0.0..=CORNERS_MAX).contains(&scale) {
                shape.note(format!(
                    "{}: {scale} is outside 0 to {CORNERS_MAX}, so the nearest end is used",
                    shape.named("corners")
                ));
            }
            Some(scale.clamp(0.0, CORNERS_MAX))
        }
        _ => {
            shape.note(format!(
                "{} must be sharp, standard, round or a number from 0 to {CORNERS_MAX}",
                shape.named("corners")
            ));
            None
        }
    }
}

fn read_cover_size(layout: &Reader) -> Option<i32> {
    let size = layout.number("cover_size")?;
    if !(COVER_SIZE_MIN as f64..=COVER_SIZE_MAX as f64).contains(&size) {
        layout.note(format!(
            "{}: {size} is outside {COVER_SIZE_MIN} to {COVER_SIZE_MAX}, so the nearest end is used",
            layout.named("cover_size")
        ));
    }
    Some((size.round() as i32).clamp(COVER_SIZE_MIN, COVER_SIZE_MAX))
}

/// The `[fonts]`, `[shape]` and `[layout]` tables of a theme or of one variant.
fn read_style(root: &Reader) -> Style {
    let mut style = Style::default();
    if let Some(fonts) = root.table("fonts") {
        style.interface_font = fonts.text("interface");
        style.heading_font = fonts.text("headings");
        fonts.finish();
    }
    if let Some(shape) = root.table("shape") {
        style.corners = read_corners(&shape);
        style.covers = shape.choice("covers", &SHAPES);
        style.shadows = shape.flag("shadows");
        shape.finish();
    }
    if let Some(layout) = root.table("layout") {
        style.albums = layout.choice("albums", &VIEWS);
        style.cover_size = read_cover_size(&layout);
        style.glow = layout.flag("glow");
        layout.finish();
    }
    style
}

fn read_colors(scheme: &Reader, key: &'static str) -> Colors {
    let Some(mode) = scheme.table(key) else {
        return Colors::default();
    };
    let colors = Colors {
        window: mode.color("window"),
        view: mode.color("view"),
        sidebar: mode.color("sidebar"),
        headerbar: mode.color("headerbar"),
        card: mode.color("card"),
        popover: mode.color("popover"),
        text: mode.color("text"),
        accent: mode.color("accent"),
        accent_text: mode.color("accent_text"),
        on_accent: mode.color("on_accent"),
        wash_a: mode.color("wash_a"),
        wash_b: mode.color("wash_b"),
    };
    mode.finish();
    colors
}

fn read_accent(scheme: &Reader) -> Accent {
    match scheme.text("accent") {
        None => Accent::Artwork,
        Some(text) if text.eq_ignore_ascii_case("artwork") => Accent::Artwork,
        Some(text) => match parse_hex(&text) {
            Some(color) => Accent::Fixed(color),
            None => {
                scheme.note(format!(
                    "{}: \"{text}\" is not a color (write it as #rrggbb, or \"artwork\" to follow the cover)",
                    scheme.named("accent")
                ));
                Accent::Artwork
            }
        },
    }
}

/// A name cut down to what an id may hold: lowercase letters, digits and
/// single dashes.
pub fn slug(name: &str) -> String {
    let mut out = String::new();
    for c in name.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if !out.is_empty() && !out.ends_with('-') {
            out.push('-');
        }
    }
    out.trim_end_matches('-').to_string()
}

/// An id for the `index`th entry: its own `id`, else its name's slug, else its
/// position, and never one an earlier entry already took.
fn entry_id(reader: &Reader, name: &str, kind: &str, index: usize, taken: &[String]) -> String {
    let wanted = reader
        .text("id")
        .map(|id| slug(&id))
        .filter(|id| !id.is_empty())
        .or_else(|| Some(slug(name)).filter(|id| !id.is_empty()))
        .unwrap_or_else(|| format!("{kind}-{}", index + 1));
    if !taken.contains(&wanted) {
        return wanted;
    }
    reader.note(format!(
        "{}: the id \"{wanted}\" is used twice, so this one becomes \"{wanted}-{}\"",
        reader.path,
        index + 1
    ));
    format!("{wanted}-{}", index + 1)
}

fn read_schemes(root: &Reader) -> Vec<Scheme> {
    let mut schemes: Vec<Scheme> = Vec::new();
    for (index, reader) in root.tables("scheme").into_iter().enumerate() {
        let name = reader
            .text("name")
            .unwrap_or_else(|| format!("Colors {}", index + 1));
        let taken: Vec<String> = schemes.iter().map(|scheme| scheme.id.clone()).collect();
        let scheme = Scheme {
            id: entry_id(&reader, &name, "scheme", index, &taken),
            name,
            accent: read_accent(&reader),
            muted: reader.flag("muted").unwrap_or(false),
            appearance: reader.choice("appearance", &APPEARANCES),
            dark: read_colors(&reader, "dark"),
            light: read_colors(&reader, "light"),
        };
        reader.finish();
        schemes.push(scheme);
    }
    if schemes.is_empty() {
        schemes.push(Scheme {
            id: "default".to_string(),
            name: "Default".to_string(),
            accent: Accent::Artwork,
            muted: false,
            appearance: None,
            dark: Colors::default(),
            light: Colors::default(),
        });
    }
    schemes
}

fn read_variants(root: &Reader) -> Vec<Variant> {
    let mut variants: Vec<Variant> = Vec::new();
    for (index, reader) in root.tables("variant").into_iter().enumerate() {
        let name = reader
            .text("name")
            .unwrap_or_else(|| format!("Variant {}", index + 1));
        let taken: Vec<String> = variants.iter().map(|variant| variant.id.clone()).collect();
        let variant = Variant {
            id: entry_id(&reader, &name, "variant", index, &taken),
            name,
            style: read_style(&reader),
        };
        reader.finish();
        variants.push(variant);
    }
    variants
}

/// Reads a `theme.toml`. A file that is not TOML, has no name or was written
/// for a newer Flaccy is refused with the reason; anything smaller (a misspelt
/// key, a color that is not one) is skipped and listed in `warnings`, and the
/// rest of the theme still applies.
pub fn parse(id: &str, document: &str) -> Result<Pack, String> {
    let table: toml::Table = document.parse().map_err(|error: toml::de::Error| {
        format!("theme.toml is not valid TOML: {}", error.message())
    })?;
    let notes = RefCell::new(Vec::new());
    let root = Reader::root(&table, &notes);

    let format = root.number("format").unwrap_or(FORMAT as f64);
    if format > FORMAT as f64 {
        return Err(format!(
            "This theme is written for a newer Flaccy (format {format}, this one reads up to {FORMAT})."
        ));
    }
    let name = root.text("name").ok_or_else(|| {
        "theme.toml has no name. Add a line like name = \"My Theme\".".to_string()
    })?;

    let pack = Pack {
        id: id.to_string(),
        name,
        author: root.text("author").unwrap_or_default(),
        description: root.text("description").unwrap_or_default(),
        appearance: root
            .choice("appearance", &APPEARANCES)
            .unwrap_or(Appearance::Any),
        style: read_style(&root),
        schemes: read_schemes(&root),
        variants: read_variants(&root),
        css: None,
        dir: None,
        builtin: false,
        warnings: Vec::new(),
    };
    root.finish();
    Ok(Pack {
        warnings: notes.into_inner(),
        ..pack
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const FULL: &str = r##"
format = 1
name = "Phosphor"
author = "Someone"
description = "A terminal."
appearance = "dark"

[fonts]
interface = "JetBrains Mono, monospace"
headings = "VT323"

[shape]
corners = "sharp"
covers = "square"
shadows = false

[layout]
albums = "list"
cover_size = 200
glow = false

[[scheme]]
name = "Green"
accent = "#39ff7a"
[scheme.dark]
window = "#050805"
text = "#b6ffcb"

[[scheme]]
id = "amber"
name = "Amber Glow"
accent = "#ffb000"
muted = true
appearance = "light"

[[variant]]
name = "Wall"
[variant.layout]
albums = "wall"
[variant.shape]
corners = 1.25
"##;

    #[test]
    fn reads_every_part_of_a_theme() {
        let pack = parse("phosphor", FULL).unwrap();
        assert_eq!(pack.warnings, Vec::<String>::new());
        assert_eq!(pack.id, "phosphor");
        assert_eq!(pack.name, "Phosphor");
        assert_eq!(pack.author, "Someone");
        assert_eq!(pack.appearance, Appearance::Dark);
        assert_eq!(
            pack.style.interface_font.as_deref(),
            Some("JetBrains Mono, monospace")
        );
        assert_eq!(pack.style.heading_font.as_deref(), Some("VT323"));
        assert_eq!(pack.style.corners, Some(CORNERS_SHARP));
        assert_eq!(pack.style.covers, Some(CoverShape::Square));
        assert_eq!(pack.style.shadows, Some(false));
        assert_eq!(pack.style.albums, Some(AlbumsView::List));
        assert_eq!(pack.style.cover_size, Some(200));
        assert_eq!(pack.style.glow, Some(false));

        assert_eq!(pack.schemes.len(), 2);
        assert_eq!(pack.schemes[0].id, "green");
        assert_eq!(pack.schemes[0].accent, Accent::Fixed((0x39, 0xff, 0x7a)));
        assert_eq!(pack.schemes[0].dark.window, Some((0x05, 0x08, 0x05)));
        assert_eq!(pack.schemes[0].dark.text, Some((0xb6, 0xff, 0xcb)));
        assert_eq!(pack.schemes[0].light, Colors::default());
        assert_eq!(pack.schemes[1].id, "amber");
        assert!(pack.schemes[1].muted);
        assert_eq!(pack.schemes[1].appearance, Some(Appearance::Light));

        assert_eq!(pack.variants.len(), 1);
        assert_eq!(pack.variants[0].id, "wall");
        assert_eq!(pack.variants[0].style.albums, Some(AlbumsView::Wall));
        assert_eq!(pack.variants[0].style.corners, Some(1.25));
    }

    #[test]
    fn a_name_alone_is_a_whole_theme() {
        let pack = parse("plain", "name = \"Plain\"").unwrap();
        assert!(pack.warnings.is_empty());
        assert!(pack.style.is_empty());
        assert_eq!(pack.appearance, Appearance::Any);
        assert_eq!(pack.schemes.len(), 1);
        assert_eq!(pack.schemes[0].accent, Accent::Artwork);
        assert!(pack.variants.is_empty());
    }

    #[test]
    fn refuses_what_it_cannot_use_at_all() {
        assert!(parse("x", "name = ")
            .unwrap_err()
            .contains("not valid TOML"));
        assert!(parse("x", "author = \"me\"")
            .unwrap_err()
            .contains("no name"));
        assert!(parse("x", "name = \"   \"")
            .unwrap_err()
            .contains("no name"));
        let newer = parse("x", "format = 2\nname = \"Later\"").unwrap_err();
        assert!(newer.contains("newer Flaccy"), "{newer}");
    }

    #[test]
    fn names_each_mistake_and_keeps_the_rest() {
        let pack = parse(
            "typo",
            r##"
name = "Typo"
colour = "red"
appearance = "night"
[layout]
albums = "gird"
cover_size = 900
glow = "yes"
[shape]
corners = 7
covrs = "square"
[[scheme]]
name = "One"
accent = "pink"
[scheme.dark]
window = "#12"
[[scheme]]
name = "One"
"##,
        )
        .unwrap();
        let all = pack.warnings.join("\n");
        for expected in [
            "colour is not something a theme can set",
            "appearance: \"night\" is not one of any, dark, light",
            "layout.albums: \"gird\" is not one of grid, wall, list, carousel",
            "layout.cover_size: 900 is outside 96 to 320",
            "layout.glow must be true or false",
            "shape.corners: 7 is outside 0 to 2",
            "shape.covrs is not something a theme can set",
            "scheme 1.accent: \"pink\" is not a color",
            "scheme 1.dark.window: \"#12\" is not a color",
            "the id \"one\" is used twice",
        ] {
            assert!(all.contains(expected), "missing: {expected}\n{all}");
        }
        assert_eq!(pack.warnings.len(), 10, "{all}");
        assert_eq!(pack.appearance, Appearance::Any);
        assert_eq!(pack.style.albums, None);
        assert_eq!(pack.style.cover_size, Some(COVER_SIZE_MAX));
        assert_eq!(pack.style.corners, Some(CORNERS_MAX));
        assert_eq!(pack.schemes[0].accent, Accent::Artwork);
        assert_eq!(pack.schemes[1].id, "one-2");
    }

    #[test]
    fn a_layer_wins_over_the_one_beneath_only_where_it_speaks() {
        let base = Style {
            albums: Some(AlbumsView::Grid),
            cover_size: Some(160),
            glow: Some(true),
            ..Style::default()
        };
        let top = Style {
            albums: Some(AlbumsView::Carousel),
            covers: Some(CoverShape::Circle),
            ..Style::default()
        };
        let merged = top.over(&base);
        assert_eq!(merged.albums, Some(AlbumsView::Carousel));
        assert_eq!(merged.cover_size, Some(160));
        assert_eq!(merged.covers, Some(CoverShape::Circle));
        assert_eq!(merged.glow, Some(true));
    }

    #[test]
    fn slugs_keep_letters_digits_and_single_dashes() {
        assert_eq!(slug("Amber Glow"), "amber-glow");
        assert_eq!(slug("  Hi-Fi  '77! "), "hi-fi-77");
        assert_eq!(slug("¡¡¡"), "");
    }
}
