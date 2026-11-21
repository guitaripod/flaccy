use super::pack::{parse, Pack};
use std::rc::Rc;

/// The id of Flaccy's own theme, the one an empty or unknown choice lands on.
pub const DEFAULT_ID: &str = "flaccy";

/// A theme that ships inside the app: its id, its `theme.toml` and its
/// stylesheet. They are the same documents a person's own theme is made of, so
/// each one doubles as a worked example to copy and change.
pub struct Source {
    pub id: &'static str,
    pub document: &'static str,
    pub css: &'static str,
}

pub const SOURCES: [Source; 6] = [
    Source {
        id: DEFAULT_ID,
        document: include_str!("../../data/themes/flaccy/theme.toml"),
        css: "",
    },
    Source {
        id: "phosphor",
        document: include_str!("../../data/themes/phosphor/theme.toml"),
        css: include_str!("../../data/themes/phosphor/style.css"),
    },
    Source {
        id: "marquee",
        document: include_str!("../../data/themes/marquee/theme.toml"),
        css: include_str!("../../data/themes/marquee/style.css"),
    },
    Source {
        id: "gallery",
        document: include_str!("../../data/themes/gallery/theme.toml"),
        css: include_str!("../../data/themes/gallery/style.css"),
    },
    Source {
        id: "liner-notes",
        document: include_str!("../../data/themes/liner-notes/theme.toml"),
        css: include_str!("../../data/themes/liner-notes/style.css"),
    },
    Source {
        id: "hi-fi",
        document: include_str!("../../data/themes/hi-fi/theme.toml"),
        css: include_str!("../../data/themes/hi-fi/style.css"),
    },
];

pub fn source(id: &str) -> Option<&'static Source> {
    SOURCES.iter().find(|source| source.id == id)
}

/// Every built-in theme, parsed. A built-in that failed to parse would be a
/// build mistake, which `every_builtin_reads_clean` catches before it ships.
pub fn packs() -> Vec<Rc<Pack>> {
    SOURCES
        .iter()
        .filter_map(|source| {
            let pack = parse(source.id, source.document).ok()?;
            Some(Rc::new(Pack {
                css: Some(source.css.to_string()).filter(|css| !css.trim().is_empty()),
                builtin: true,
                ..pack
            }))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::super::color::contrast;
    use super::super::look::{Choice, Look};
    use super::super::pack::{Appearance, Style};
    use super::*;

    #[test]
    fn every_builtin_reads_clean() {
        let packs = packs();
        assert_eq!(packs.len(), SOURCES.len());
        for pack in &packs {
            assert_eq!(pack.warnings, Vec::<String>::new(), "{}", pack.id);
            assert!(
                !pack.description.is_empty(),
                "{} has no description",
                pack.id
            );
            assert!(pack.builtin);
        }
        assert_eq!(packs[0].id, DEFAULT_ID);
    }

    #[test]
    fn flaccys_own_theme_keeps_the_seven_palettes_under_their_old_ids() {
        let own = &packs()[0];
        let ids: Vec<&str> = own
            .schemes
            .iter()
            .map(|scheme| scheme.id.as_str())
            .collect();
        assert_eq!(
            ids,
            [
                "adaptive",
                "rosewater",
                "aurora",
                "nocturne",
                "verdant",
                "sunset",
                "mono"
            ]
        );
        assert!(own.style.is_empty());
        assert!(own.css.is_none());
        assert_eq!(own.appearance, Appearance::Any);
    }

    #[test]
    fn every_scheme_of_every_builtin_is_readable_where_it_is_shown() {
        for pack in packs() {
            for scheme in &pack.schemes {
                let choice = Choice {
                    pack: pack.id.clone(),
                    scheme: scheme.id.clone(),
                    variant: String::new(),
                };
                let look = Look::resolve(&pack, &choice, &Style::default());
                let modes: &[bool] = match look.appearance() {
                    Appearance::Dark => &[true],
                    Appearance::Light => &[false],
                    Appearance::Any => &[true, false],
                };
                for dark in modes {
                    let palette = look.palette(*dark, None);
                    let name = format!("{} / {} / dark={dark}", pack.id, scheme.id);
                    let fallback = if *dark {
                        (0xff, 0xff, 0xff)
                    } else {
                        (0x1e, 0x1e, 0x20)
                    };
                    let text = palette.text.unwrap_or(fallback);
                    for (surface, color) in [
                        ("window", palette.window),
                        ("view", palette.view),
                        ("sidebar", palette.sidebar),
                        ("headerbar", palette.headerbar),
                        ("card", palette.surface),
                        ("popover", palette.popover),
                    ] {
                        assert!(
                            contrast(text, color) >= 7.0,
                            "{name}: text on {surface} is {:.1}:1",
                            contrast(text, color)
                        );
                    }
                    assert!(
                        contrast(palette.accent_fg, palette.accent_bg) >= 3.0,
                        "{name}: text on the accent is {:.1}:1",
                        contrast(palette.accent_fg, palette.accent_bg)
                    );
                    assert!(
                        contrast(palette.accent_text, palette.window) >= 4.5,
                        "{name}: accent text on the window is {:.1}:1",
                        contrast(palette.accent_text, palette.window)
                    );
                }
            }
        }
    }
}
