/// A color as its red, green and blue bytes.
pub type Rgb = (u8, u8, u8);

#[derive(Clone, Copy)]
pub struct Hsl {
    pub h: f64,
    pub s: f64,
    pub l: f64,
}

pub fn rgb_to_hsl((r, g, b): Rgb) -> Hsl {
    let r = r as f64 / 255.0;
    let g = g as f64 / 255.0;
    let b = b as f64 / 255.0;
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let l = (max + min) / 2.0;
    let delta = max - min;
    if delta < 1e-6 {
        return Hsl { h: 0.0, s: 0.0, l };
    }
    let s = delta / (1.0 - (2.0 * l - 1.0).abs());
    let h = if max == r {
        60.0 * (((g - b) / delta).rem_euclid(6.0))
    } else if max == g {
        60.0 * (((b - r) / delta) + 2.0)
    } else {
        60.0 * (((r - g) / delta) + 4.0)
    };
    Hsl { h, s, l }
}

pub fn hsl_to_rgb(hsl: Hsl) -> Rgb {
    let Hsl { h, s, l } = hsl;
    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let hp = (h.rem_euclid(360.0)) / 60.0;
    let x = c * (1.0 - (hp.rem_euclid(2.0) - 1.0).abs());
    let (r1, g1, b1) = match hp as i32 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let m = l - c / 2.0;
    (
        (((r1 + m) * 255.0).round()).clamp(0.0, 255.0) as u8,
        (((g1 + m) * 255.0).round()).clamp(0.0, 255.0) as u8,
        (((b1 + m) * 255.0).round()).clamp(0.0, 255.0) as u8,
    )
}

pub fn hex(rgb: Rgb) -> String {
    format!("#{:02x}{:02x}{:02x}", rgb.0, rgb.1, rgb.2)
}

/// Reads `#rgb` or `#rrggbb`, with or without the `#`.
pub fn parse_hex(text: &str) -> Option<Rgb> {
    let digits = text.trim().trim_start_matches('#');
    if !digits.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let byte = |at: usize| u8::from_str_radix(&digits[at..at + 2], 16).ok();
    let nibble = |at: usize| {
        u8::from_str_radix(&digits[at..at + 1], 16)
            .ok()
            .map(|n| n * 17)
    };
    match digits.len() {
        6 => Some((byte(0)?, byte(2)?, byte(4)?)),
        3 => Some((nibble(0)?, nibble(1)?, nibble(2)?)),
        _ => None,
    }
}

/// Relative luminance, the measure a legible foreground is chosen by.
pub fn luminance(rgb: Rgb) -> f64 {
    let channel = |c: u8| {
        let c = c as f64 / 255.0;
        if c <= 0.03928 {
            c / 12.92
        } else {
            ((c + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * channel(rgb.0) + 0.7152 * channel(rgb.1) + 0.0722 * channel(rgb.2)
}

/// The WCAG contrast ratio between two colors, from 1 to 21.
pub fn contrast(a: Rgb, b: Rgb) -> f64 {
    let (la, lb) = (luminance(a), luminance(b));
    (la.max(lb) + 0.05) / (la.min(lb) + 0.05)
}

const WHITE: Rgb = (0xff, 0xff, 0xff);
const NEAR_BLACK: Rgb = (0x11, 0x11, 0x14);

/// The least contrast a glyph or label needs against the fill it sits on.
const GLYPH_CONTRAST: f64 = 3.0;

/// The foreground for a fill of `background`: white wherever white is
/// readable on it, near-black on anything lighter. The old rule switched at a
/// luminance of 0.55, which left white on a teal or orange accent at under
/// 2:1.
pub fn legible_on(background: Rgb) -> Rgb {
    if contrast(WHITE, background) >= GLYPH_CONTRAST {
        WHITE
    } else {
        NEAR_BLACK
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_reads_both_lengths_and_refuses_the_rest() {
        assert_eq!(parse_hex("#ff4d6d"), Some((0xff, 0x4d, 0x6d)));
        assert_eq!(parse_hex("FF4D6D"), Some((0xff, 0x4d, 0x6d)));
        assert_eq!(parse_hex("#0f8"), Some((0x00, 0xff, 0x88)));
        assert_eq!(parse_hex("#ff4d6"), None);
        assert_eq!(parse_hex("rose"), None);
        assert_eq!(parse_hex("#ggg"), None);
        assert_eq!(parse_hex("#ééé"), None);
    }

    #[test]
    fn hsl_round_trips() {
        for rgb in [
            (0xff, 0x4d, 0x6d),
            (0x2d, 0xd4, 0xbf),
            (0x10, 0x10, 0x10),
            (0xff, 0xff, 0xff),
        ] {
            let back = hsl_to_rgb(rgb_to_hsl(rgb));
            assert!(
                (back.0 as i32 - rgb.0 as i32).abs() <= 1,
                "{rgb:?} -> {back:?}"
            );
            assert!(
                (back.1 as i32 - rgb.1 as i32).abs() <= 1,
                "{rgb:?} -> {back:?}"
            );
            assert!(
                (back.2 as i32 - rgb.2 as i32).abs() <= 1,
                "{rgb:?} -> {back:?}"
            );
        }
    }

    #[test]
    fn contrast_spans_one_to_twenty_one() {
        assert!((contrast((0, 0, 0), (255, 255, 255)) - 21.0).abs() < 0.01);
        assert!((contrast((40, 40, 40), (40, 40, 40)) - 1.0).abs() < 0.01);
        assert_eq!(legible_on((250, 250, 240)), NEAR_BLACK);
        assert_eq!(legible_on((20, 20, 30)), WHITE);
    }

    #[test]
    fn a_fill_always_gets_a_foreground_that_reads_on_it() {
        for red in (0..=255).step_by(15) {
            for green in (0..=255).step_by(15) {
                for blue in (0..=255).step_by(15) {
                    let fill = (red as u8, green as u8, blue as u8);
                    assert!(
                        contrast(legible_on(fill), fill) >= GLYPH_CONTRAST,
                        "{fill:?} gets an unreadable foreground"
                    );
                }
            }
        }
        assert_eq!(
            legible_on((0xf6, 0x27, 0x52)),
            WHITE,
            "the brand rose keeps its white glyphs"
        );
        assert_eq!(
            legible_on((0x2d, 0xd4, 0xbf)),
            NEAR_BLACK,
            "teal is too light for white"
        );
    }
}
