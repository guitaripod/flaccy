use super::color::{contrast, hsl_to_rgb, legible_on, rgb_to_hsl, Hsl, Rgb};
use super::pack::{
    Accent, AlbumsView, Appearance, Colors, CoverShape, Pack, Scheme, Style, CORNERS_MAX,
    CORNERS_STANDARD, COVER_SIZE_DEFAULT, COVER_SIZE_MAX, COVER_SIZE_MIN,
};
use crate::config::Config;
use std::rc::Rc;

/// The brand rose an artwork-following scheme wears until something plays.
pub const BRAND_SEED: Rgb = (0xFF, 0x4D, 0x6D);

/// Which theme is on, and which of its color schemes and variants.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Choice {
    pub pack: String,
    pub scheme: String,
    pub variant: String,
}

impl Choice {
    pub fn from_config(config: &Config) -> Choice {
        Choice {
            pack: config.theme_pack.clone(),
            scheme: config.theme.clone(),
            variant: config.theme_variant.clone(),
        }
    }
}

/// The person's own choices, laid over whatever the theme says. They are read
/// from `config.toml`, where an empty or zero value means "as the theme has it".
pub fn overrides_from_config(config: &Config) -> Style {
    Style {
        interface_font: Some(config.look_font.trim().to_string()).filter(|font| !font.is_empty()),
        heading_font: None,
        corners: match config.look_corners.as_str() {
            "sharp" => Some(super::pack::CORNERS_SHARP),
            "standard" => Some(CORNERS_STANDARD),
            "round" => Some(super::pack::CORNERS_ROUND),
            _ => None,
        },
        covers: CoverShape::from_id(&config.look_covers),
        shadows: None,
        albums: AlbumsView::from_id(&config.albums_view),
        cover_size: Some(config.look_cover_size)
            .filter(|size| *size > 0)
            .map(|size| size.clamp(COVER_SIZE_MIN, COVER_SIZE_MAX)),
        glow: match config.look_glow.as_str() {
            "on" => Some(true),
            "off" => Some(false),
            _ => None,
        },
    }
}

/// Every color the app is drawn with in one mode.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Palette {
    pub accent_bg: Rgb,
    pub accent_fg: Rgb,
    pub accent_text: Rgb,
    pub wash_a: Rgb,
    pub wash_b: Rgb,
    pub surface: Rgb,
    pub window: Rgb,
    pub headerbar: Rgb,
    pub sidebar: Rgb,
    pub view: Rgb,
    pub popover: Rgb,
    pub text: Option<Rgb>,
}

/// The least contrast accent-colored text keeps against the window it is on.
const ACCENT_TEXT_CONTRAST: f64 = 4.5;

/// The accent as a text color: the hue at `lightness`, moved further from the
/// window's own lightness in small steps until it reads. Teal, green and
/// orange at the lightness rose is readable at were under 2.5:1 on a light
/// window.
fn accent_text_on(window: Rgb, hue: f64, saturation: f64, lightness: f64, dark: bool) -> Rgb {
    let step = if dark { 0.02 } else { -0.02 };
    let mut lightness = lightness;
    loop {
        let text = hsl_to_rgb(Hsl {
            h: hue,
            s: saturation,
            l: lightness,
        });
        let next = lightness + step;
        if contrast(text, window) >= ACCENT_TEXT_CONTRAST || !(0.04..=0.96).contains(&next) {
            return text;
        }
        lightness = next;
    }
}

/// Works a whole palette out of one seed color. Album artwork often yields
/// muddy or blown-out colors, so the hue is kept while saturation and
/// lightness are pulled into a legible, vivid band.
pub fn derive(seed: Rgb, muted: bool, dark: bool) -> Palette {
    let base = rgb_to_hsl(seed);
    let hue = base.h;
    let sat = if muted {
        (base.s * 0.35).clamp(0.0, 0.18)
    } else {
        base.s.clamp(0.55, 0.92)
    };

    let accent_bg = hsl_to_rgb(Hsl {
        h: hue,
        s: sat,
        l: if dark { 0.56 } else { 0.50 },
    });
    let tint = |s_mul: f64, s_cap: f64, l: f64, h_shift: f64| {
        hsl_to_rgb(Hsl {
            h: (hue + h_shift).rem_euclid(360.0),
            s: (sat * s_mul).min(s_cap),
            l,
        })
    };

    let (wash_a, wash_b, surface, window, headerbar, sidebar, view) = if dark {
        (
            tint(0.9, 0.85, 0.20, 0.0),
            tint(0.85, 0.80, 0.11, 28.0),
            tint(0.40, 0.35, 0.145, 0.0),
            tint(0.35, 0.28, 0.082, 0.0),
            tint(0.35, 0.26, 0.118, 0.0),
            tint(0.35, 0.26, 0.10, 0.0),
            tint(0.30, 0.22, 0.105, 0.0),
        )
    } else {
        (
            tint(0.70, 0.60, 0.93, 0.0),
            tint(0.60, 0.50, 0.97, 28.0),
            tint(0.30, 0.22, 0.985, 0.0),
            tint(0.28, 0.18, 0.965, 0.0),
            tint(0.26, 0.16, 0.982, 0.0),
            tint(0.30, 0.20, 0.955, 0.0),
            tint(0.20, 0.14, 0.995, 0.0),
        )
    };

    Palette {
        accent_bg,
        accent_fg: legible_on(accent_bg),
        accent_text: accent_text_on(
            window,
            hue,
            (sat + 0.05).min(0.95),
            if dark { 0.72 } else { 0.42 },
            dark,
        ),
        wash_a,
        wash_b,
        surface,
        window,
        headerbar,
        sidebar,
        view,
        popover: headerbar,
        text: None,
    }
}

/// `derived` with every color the scheme states exactly put in its place. An
/// exact accent takes a legible foreground with it unless one is stated too,
/// and an exact header bar carries the popovers that share its color.
fn with_exact(derived: Palette, exact: &Colors) -> Palette {
    let accent_bg = exact.accent.unwrap_or(derived.accent_bg);
    let headerbar = exact.headerbar.unwrap_or(derived.headerbar);
    Palette {
        accent_bg,
        accent_fg: exact.on_accent.unwrap_or_else(|| {
            if exact.accent.is_some() {
                legible_on(accent_bg)
            } else {
                derived.accent_fg
            }
        }),
        accent_text: exact.accent_text.unwrap_or(derived.accent_text),
        wash_a: exact.wash_a.unwrap_or(derived.wash_a),
        wash_b: exact.wash_b.unwrap_or(derived.wash_b),
        surface: exact.card.unwrap_or(derived.surface),
        window: exact.window.unwrap_or(derived.window),
        headerbar,
        sidebar: exact.sidebar.unwrap_or(derived.sidebar),
        view: exact.view.unwrap_or(derived.view),
        popover: exact.popover.unwrap_or(headerbar),
        text: exact.text,
    }
}

/// What the app actually wears: a theme with one of its schemes and variants
/// chosen and the person's own choices laid on top.
#[derive(Clone, Debug, PartialEq)]
pub struct Look {
    pub pack: Rc<Pack>,
    pub scheme: usize,
    pub variant: Option<usize>,
    pub interface_font: Option<String>,
    pub heading_font: Option<String>,
    pub corners: f64,
    pub covers: CoverShape,
    pub shadows: bool,
    pub albums: AlbumsView,
    pub cover_size: i32,
    pub glow: bool,
}

impl Look {
    pub fn resolve(pack: &Rc<Pack>, choice: &Choice, overrides: &Style) -> Look {
        let scheme = pack
            .schemes
            .iter()
            .position(|scheme| scheme.id == choice.scheme)
            .unwrap_or(0);
        let variant = if pack.variants.is_empty() {
            None
        } else {
            Some(
                pack.variants
                    .iter()
                    .position(|variant| variant.id == choice.variant)
                    .unwrap_or(0),
            )
        };
        let themed = match variant {
            Some(index) => pack.variants[index].style.over(&pack.style),
            None => pack.style.clone(),
        };
        let style = overrides.over(&themed);
        Look {
            pack: Rc::clone(pack),
            scheme,
            variant,
            interface_font: style.interface_font,
            heading_font: style.heading_font,
            corners: style
                .corners
                .unwrap_or(CORNERS_STANDARD)
                .clamp(0.0, CORNERS_MAX),
            covers: style.covers.unwrap_or(CoverShape::Rounded),
            shadows: style.shadows.unwrap_or(true),
            albums: style.albums.unwrap_or(AlbumsView::Grid),
            cover_size: style
                .cover_size
                .unwrap_or(COVER_SIZE_DEFAULT)
                .clamp(COVER_SIZE_MIN, COVER_SIZE_MAX),
            glow: style.glow.unwrap_or(true),
        }
    }

    pub fn scheme(&self) -> &Scheme {
        &self.pack.schemes[self.scheme]
    }

    /// The mode this look insists on: its scheme's when the scheme has one,
    /// otherwise the theme's.
    pub fn appearance(&self) -> Appearance {
        self.scheme().appearance.unwrap_or(self.pack.appearance)
    }

    pub fn follows_artwork(&self) -> bool {
        self.scheme().accent == Accent::Artwork
    }

    /// The color everything is derived from: the scheme's own, or the playing
    /// cover's when the scheme follows artwork.
    pub fn seed(&self, artwork: Option<Rgb>) -> Rgb {
        match self.scheme().accent {
            Accent::Fixed(color) => color,
            Accent::Artwork => artwork.unwrap_or(BRAND_SEED),
        }
    }

    pub fn palette(&self, dark: bool, artwork: Option<Rgb>) -> Palette {
        let scheme = self.scheme();
        let derived = derive(self.seed(artwork), scheme.muted, dark);
        with_exact(derived, if dark { &scheme.dark } else { &scheme.light })
    }
}

#[cfg(test)]
mod tests {
    use super::super::pack::{parse, CORNERS_ROUND, CORNERS_SHARP};
    use super::*;

    fn pack(document: &str) -> Rc<Pack> {
        Rc::new(parse("test", document).unwrap())
    }

    fn choice(scheme: &str, variant: &str) -> Choice {
        Choice {
            pack: "test".to_string(),
            scheme: scheme.to_string(),
            variant: variant.to_string(),
        }
    }

    const LAYERED: &str = r##"
name = "Layered"
[layout]
albums = "list"
cover_size = 180
[shape]
corners = "sharp"
[[scheme]]
name = "Rose"
accent = "#ff4d6d"
[[scheme]]
name = "Teal"
accent = "#2dd4bf"
appearance = "dark"
[scheme.dark]
window = "#000000"
text = "#e0fff8"
accent = "#00ffcc"
[[variant]]
name = "Shelf"
[[variant]]
name = "Flow"
[variant.layout]
albums = "carousel"
"##;

    #[test]
    fn a_bare_theme_resolves_to_the_look_flaccy_always_had() {
        let look = Look::resolve(
            &pack("name = \"Bare\""),
            &Choice::default(),
            &Style::default(),
        );
        assert_eq!(look.albums, AlbumsView::Grid);
        assert_eq!(look.cover_size, COVER_SIZE_DEFAULT);
        assert_eq!(look.corners, CORNERS_STANDARD);
        assert_eq!(look.covers, CoverShape::Rounded);
        assert!(look.shadows && look.glow);
        assert!(look.follows_artwork());
        assert_eq!(look.appearance(), Appearance::Any);
        assert_eq!(look.variant, None);
    }

    #[test]
    fn the_variant_lies_over_the_theme_and_the_person_over_both() {
        let layered = pack(LAYERED);
        let themed = Look::resolve(&layered, &choice("rose", "shelf"), &Style::default());
        assert_eq!(themed.albums, AlbumsView::List);
        assert_eq!(themed.cover_size, 180);
        assert_eq!(themed.corners, CORNERS_SHARP);

        let flow = Look::resolve(&layered, &choice("rose", "flow"), &Style::default());
        assert_eq!(flow.albums, AlbumsView::Carousel);
        assert_eq!(flow.cover_size, 180);

        let mine = Style {
            albums: Some(AlbumsView::Wall),
            corners: Some(CORNERS_ROUND),
            ..Style::default()
        };
        let personal = Look::resolve(&layered, &choice("rose", "flow"), &mine);
        assert_eq!(personal.albums, AlbumsView::Wall);
        assert_eq!(personal.corners, CORNERS_ROUND);
        assert_eq!(personal.cover_size, 180);
    }

    #[test]
    fn a_choice_the_theme_does_not_have_lands_on_its_first() {
        let look = Look::resolve(&pack(LAYERED), &choice("gone", "gone"), &Style::default());
        assert_eq!(look.scheme().id, "rose");
        assert_eq!(look.variant, Some(0));
    }

    #[test]
    fn exact_colors_replace_the_derived_ones_in_their_mode_only() {
        let look = Look::resolve(&pack(LAYERED), &choice("teal", ""), &Style::default());
        assert_eq!(look.appearance(), Appearance::Dark);
        let dark = look.palette(true, None);
        assert_eq!(dark.window, (0, 0, 0));
        assert_eq!(dark.text, Some((0xe0, 0xff, 0xf8)));
        assert_eq!(dark.accent_bg, (0x00, 0xff, 0xcc));
        assert_eq!(dark.accent_fg, (0x11, 0x11, 0x14));
        let light = look.palette(false, None);
        assert_eq!(light, derive((0x2d, 0xd4, 0xbf), false, false));
    }

    #[test]
    fn an_artwork_scheme_takes_the_cover_and_a_fixed_one_ignores_it() {
        let bare = Look::resolve(
            &pack("name = \"Bare\""),
            &Choice::default(),
            &Style::default(),
        );
        assert_eq!(bare.seed(None), BRAND_SEED);
        assert_eq!(bare.seed(Some((1, 2, 3))), (1, 2, 3));
        let fixed = Look::resolve(&pack(LAYERED), &choice("rose", ""), &Style::default());
        assert!(!fixed.follows_artwork());
        assert_eq!(fixed.seed(Some((1, 2, 3))), (0xff, 0x4d, 0x6d));
    }

    #[test]
    fn a_derived_palette_keeps_its_accent_legible_in_both_modes() {
        for seed in [
            BRAND_SEED,
            (0x2d, 0xd4, 0xbf),
            (0x6e, 0x8b, 0xff),
            (0x34, 0xd3, 0x99),
            (0xfb, 0x8b, 0x24),
            (0xff, 0xf0, 0x40),
            (0x10, 0x10, 0x10),
        ] {
            for dark in [true, false] {
                let palette = derive(seed, false, dark);
                assert!(
                    contrast(palette.accent_bg, palette.accent_fg) >= 3.0,
                    "{seed:?} dark={dark}: on-accent text is unreadable"
                );
                assert!(
                    contrast(palette.accent_text, palette.window) >= ACCENT_TEXT_CONTRAST,
                    "{seed:?} dark={dark}: accent text is lost on the window"
                );
            }
        }
    }

    #[test]
    fn the_persons_choices_read_from_config() {
        let mut config = Config::default();
        assert!(overrides_from_config(&config).is_empty());
        config.albums_view = "carousel".to_string();
        config.look_cover_size = 999;
        config.look_covers = "circle".to_string();
        config.look_corners = "sharp".to_string();
        config.look_font = " Inter ".to_string();
        config.look_glow = "off".to_string();
        let mine = overrides_from_config(&config);
        assert_eq!(mine.albums, Some(AlbumsView::Carousel));
        assert_eq!(mine.cover_size, Some(COVER_SIZE_MAX));
        assert_eq!(mine.covers, Some(CoverShape::Circle));
        assert_eq!(mine.corners, Some(CORNERS_SHARP));
        assert_eq!(mine.interface_font.as_deref(), Some("Inter"));
        assert_eq!(mine.glow, Some(false));
    }
}
