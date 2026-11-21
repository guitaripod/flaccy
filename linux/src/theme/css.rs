use super::color::hex;
use super::look::{Look, Palette};
use super::pack::{CoverShape, CORNERS_SHARP};
use std::path::Path;

/// Every class a cover, sleeve or thumbnail is drawn with, so a theme's cover
/// shape and shadows reach all of them at once.
const COVER_CLASSES: &str = ".cover, .cover-large, .cover-thumb, .playlist-thumb, .mini-art, \
                             .home-jump-cover, .album-detail-cover, .flow-cover, .wall-tile, .list-cover";

/// Every class a title is set in, for a theme that gives headings a typeface
/// of their own.
const HEADING_CLASSES: &str = ".title-1, .title-2, .title-3, .title-4, .large-title, .heading, \
                               .album-title, .artist-hero-name, .artist-section-title, .flow-title";

/// A radius at or past this is a pill or a circle, which stays one however
/// round or square the corners get, unless they are fully sharp.
const PILL_RADIUS: f64 = 999.0;

const GENERIC_FAMILIES: [&str; 8] = [
    "serif",
    "sans-serif",
    "monospace",
    "cursive",
    "fantasy",
    "system-ui",
    "ui-monospace",
    "ui-rounded",
];

/// The named colors libadwaita and the app stylesheet key off, redefined for
/// one palette. Swapping this in live retints the entire app.
pub fn palette_css(palette: &Palette) -> String {
    let mut css = format!(
        "@define-color accent_bg_color {accent_bg};\n\
         @define-color accent_color {accent_text};\n\
         @define-color accent_fg_color {accent_fg};\n\
         @define-color flaccy_accent {accent_bg};\n\
         @define-color flaccy_accent_text {accent_text};\n\
         @define-color flaccy_wash_a {wash_a};\n\
         @define-color flaccy_wash_b {wash_b};\n\
         @define-color flaccy_surface {surface};\n\
         @define-color window_bg_color {window};\n\
         @define-color view_bg_color {view};\n\
         @define-color headerbar_bg_color {headerbar};\n\
         @define-color sidebar_bg_color {sidebar};\n\
         @define-color card_bg_color {surface};\n\
         @define-color popover_bg_color {popover};\n\
         @define-color dialog_bg_color {headerbar};\n",
        accent_bg = hex(palette.accent_bg),
        accent_text = hex(palette.accent_text),
        accent_fg = hex(palette.accent_fg),
        wash_a = hex(palette.wash_a),
        wash_b = hex(palette.wash_b),
        surface = hex(palette.surface),
        window = hex(palette.window),
        view = hex(palette.view),
        headerbar = hex(palette.headerbar),
        sidebar = hex(palette.sidebar),
        popover = hex(palette.popover),
    );
    if let Some(text) = palette.text {
        for name in [
            "window",
            "view",
            "headerbar",
            "sidebar",
            "card",
            "popover",
            "dialog",
        ] {
            css.push_str(&format!("@define-color {name}_fg_color {};\n", hex(text)));
        }
    }
    css
}

/// A font list as CSS takes it: each family in quotes, generic names bare,
/// and nothing that could close the rule it sits in.
pub fn css_font_stack(families: &str) -> String {
    families
        .split(',')
        .map(|family| {
            family
                .chars()
                .filter(|c| !matches!(c, '"' | '\'' | ';' | '{' | '}' | '\\' | '\n' | '\r'))
                .collect::<String>()
                .trim()
                .to_string()
        })
        .filter(|family| !family.is_empty())
        .map(|family| {
            if GENERIC_FAMILIES.contains(&family.to_ascii_lowercase().as_str()) {
                family.to_ascii_lowercase()
            } else {
                format!("\"{family}\"")
            }
        })
        .collect::<Vec<_>>()
        .join(", ")
}

/// The `gtk-font-name` that sets `families` at the size the desktop's own font
/// has. The comma before the size keeps a family that ends in a number or a
/// style word ("Source Sans 3") from being read as a size or a weight.
pub fn font_setting(families: &str, desktop_font: &str) -> String {
    let size = desktop_font
        .rsplit(' ')
        .next()
        .and_then(|last| last.parse::<f64>().ok())
        .filter(|size| *size > 0.0)
        .unwrap_or(11.0);
    let families: Vec<String> = families
        .split(',')
        .map(|family| family.trim().to_string())
        .filter(|family| !family.is_empty())
        .collect();
    format!("{}, {size}", families.join(", "))
}

/// The rules a look adds beyond its colors: cover shape, shadows, the window
/// glow, heading type and fully sharp corners. Empty for the standard look.
pub fn look_css(look: &Look) -> String {
    let mut css = String::new();
    if look.corners <= CORNERS_SHARP {
        css.push_str("* { border-radius: 0; }\n");
    }
    match look.covers {
        CoverShape::Rounded => {}
        CoverShape::Square => css.push_str(&format!("{COVER_CLASSES} {{ border-radius: 0; }}\n")),
        CoverShape::Circle => {
            css.push_str(&format!("{COVER_CLASSES} {{ border-radius: 9999px; }}\n"))
        }
    }
    if !look.shadows {
        css.push_str(&format!("{COVER_CLASSES} {{ box-shadow: none; }}\n"));
    }
    if !look.glow {
        css.push_str(".flaccy-window { background-image: none; }\n");
    }
    if let Some(stack) = look
        .heading_font
        .as_deref()
        .map(css_font_stack)
        .filter(|stack| !stack.is_empty())
    {
        css.push_str(&format!("{HEADING_CLASSES} {{ font-family: {stack}; }}\n"));
    }
    css
}

fn scaled_radius(value: &str, scale: f64) -> String {
    value
        .split_whitespace()
        .map(|part| {
            match part
                .strip_suffix("px")
                .and_then(|number| number.parse::<f64>().ok())
            {
                Some(px) if px < PILL_RADIUS || scale <= 0.0 => {
                    let scaled = (px * scale * 10.0).round() / 10.0;
                    format!("{scaled}px")
                }
                _ => part.to_string(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Rewrites every `border-radius` of a stylesheet by `scale`, so one number
/// makes the app's own surfaces squarer or rounder. Pills and circles keep
/// their shape until the scale reaches zero.
pub fn scale_radii(css: &str, scale: f64) -> String {
    if (scale - 1.0).abs() < f64::EPSILON {
        return css.to_string();
    }
    const KEY: &str = "border-radius:";
    let mut out = String::with_capacity(css.len() + 64);
    let mut rest = css;
    while let Some(at) = rest.find(KEY) {
        let (head, tail) = rest.split_at(at + KEY.len());
        out.push_str(head);
        let end = tail.find([';', '}']).unwrap_or(tail.len());
        out.push(' ');
        out.push_str(&scaled_radius(&tail[..end], scale));
        rest = &tail[end..];
    }
    out.push_str(rest);
    out
}

fn percent_encoded(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    for byte in path.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                out.push(byte as char)
            }
            other => out.push_str(&format!("%{other:02X}")),
        }
    }
    out
}

fn is_relative(target: &str) -> bool {
    !(target.is_empty()
        || target.starts_with('/')
        || target.starts_with("data:")
        || target.contains("://"))
}

/// Points every relative `url(...)` of a theme's stylesheet at the theme's own
/// folder, since the sheet is handed to GTK as text and would otherwise have
/// nowhere to resolve them from.
pub fn absolute_urls(css: &str, base: &Path) -> String {
    const KEY: &str = "url(";
    let mut out = String::with_capacity(css.len() + 64);
    let mut rest = css;
    while let Some(at) = rest.find(KEY) {
        let (head, tail) = rest.split_at(at + KEY.len());
        out.push_str(head);
        let Some(end) = tail.find(')') else {
            rest = tail;
            break;
        };
        let target = tail[..end].trim().trim_matches(['"', '\'']);
        if is_relative(target) {
            let path = base.join(target);
            out.push_str(&format!(
                "\"file://{}\"",
                percent_encoded(&path.to_string_lossy())
            ));
        } else {
            out.push_str(&tail[..end]);
        }
        rest = &tail[end..];
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::super::look::{derive, Choice, BRAND_SEED};
    use super::super::pack::{parse, Style};
    use super::*;
    use std::rc::Rc;

    fn look(document: &str) -> Look {
        Look::resolve(
            &Rc::new(parse("test", document).unwrap()),
            &Choice::default(),
            &Style::default(),
        )
    }

    #[test]
    fn the_standard_look_adds_no_rule_of_its_own() {
        assert_eq!(look_css(&look("name = \"Bare\"")), "");
    }

    #[test]
    fn a_palette_defines_the_colors_flaccy_always_defined() {
        let css = palette_css(&derive(BRAND_SEED, false, true));
        assert_eq!(css.lines().count(), 15);
        assert!(css.contains("@define-color accent_bg_color #"));
        assert!(css.contains("@define-color popover_bg_color #"));
        assert!(!css.contains("window_fg_color"));
    }

    #[test]
    fn stated_text_colors_every_surface() {
        let palette = Palette {
            text: Some((0xb6, 0xff, 0xcb)),
            ..derive(BRAND_SEED, false, true)
        };
        let css = palette_css(&palette);
        for surface in [
            "window",
            "view",
            "headerbar",
            "sidebar",
            "card",
            "popover",
            "dialog",
        ] {
            assert!(
                css.contains(&format!("@define-color {surface}_fg_color #b6ffcb;")),
                "{surface}"
            );
        }
    }

    #[test]
    fn a_look_writes_only_the_rules_it_changes() {
        let css = look_css(&look(
            "name = \"T\"\n[shape]\ncorners = \"sharp\"\ncovers = \"circle\"\nshadows = false\n\
             [layout]\nglow = false\n[fonts]\nheadings = \"Charter, serif\"",
        ));
        assert!(css.contains("* { border-radius: 0; }"));
        assert!(css.contains(".cover, .cover-large"));
        assert!(css.contains("{ border-radius: 9999px; }"));
        assert!(css.contains("{ box-shadow: none; }"));
        assert!(css.contains(".flaccy-window { background-image: none; }"));
        assert!(css.contains("{ font-family: \"Charter\", serif; }"));
        let square = look_css(&look("name = \"T\"\n[shape]\ncovers = \"square\""));
        assert_eq!(square.lines().count(), 1);
        assert!(square.ends_with("{ border-radius: 0; }\n"));
    }

    #[test]
    fn a_font_stack_cannot_break_out_of_its_rule() {
        assert_eq!(
            css_font_stack("JetBrains Mono, monospace"),
            "\"JetBrains Mono\", monospace"
        );
        assert_eq!(css_font_stack("Serif"), "serif");
        assert_eq!(css_font_stack(" , "), "");
        assert_eq!(
            css_font_stack("Evil\"; } * { color: red; {"),
            "\"Evil  *  color: red\""
        );
    }

    #[test]
    fn the_font_setting_borrows_the_desktop_size() {
        assert_eq!(
            font_setting("JetBrains Mono, monospace", "Adwaita Sans 11"),
            "JetBrains Mono, monospace, 11"
        );
        assert_eq!(
            font_setting("Source Sans 3", "Noto Sans 10.5"),
            "Source Sans 3, 10.5"
        );
        assert_eq!(font_setting("Inter", "Cantarell"), "Inter, 11");
    }

    #[test]
    fn radii_scale_and_pills_stay_pills_until_sharp() {
        let css = ".a { border-radius: 10px; }\n.b { border-radius: 8px 0 8px 0; color: red; }\n\
                   .c { border-radius: 9999px; }\n.d { border-radius: 50%; }";
        assert_eq!(scale_radii(css, 1.0), css);
        let round = scale_radii(css, 1.5);
        assert!(round.contains(".a { border-radius: 15px; }"));
        assert!(round.contains(".b { border-radius: 12px 0 12px 0; color: red; }"));
        assert!(round.contains(".c { border-radius: 9999px; }"));
        assert!(round.contains(".d { border-radius: 50%; }"));
        let sharp = scale_radii(css, 0.0);
        assert!(sharp.contains(".a { border-radius: 0px; }"));
        assert!(sharp.contains(".c { border-radius: 0px; }"));
    }

    #[test]
    fn relative_urls_point_into_the_theme_folder() {
        let base = Path::new("/home/me/.local/share/flaccy/themes/My Theme");
        let css = "a { background-image: url(\"assets/paper tile.png\"); }\n\
                   b { background-image: url(noise.png), url('/abs.png'), url(data:image/png;base64,AA==); }\n\
                   c { background-image: url(https://example.com/x.png); }";
        let out = absolute_urls(css, base);
        assert!(out.contains(
            "url(\"file:///home/me/.local/share/flaccy/themes/My%20Theme/assets/paper%20tile.png\")"
        ));
        assert!(out
            .contains("url(\"file:///home/me/.local/share/flaccy/themes/My%20Theme/noise.png\")"));
        assert!(out.contains("url('/abs.png')"));
        assert!(out.contains("url(data:image/png;base64,AA==)"));
        assert!(out.contains("url(https://example.com/x.png)"));
    }
}
