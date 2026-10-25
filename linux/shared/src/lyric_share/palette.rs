//! Colours for a lyric clip: sRGB arithmetic (luminance, contrast, HSL) and the
//! palette each theme paints from the artwork's colours.
//!
//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/LyricShare/LyricSharePalette.swift`.

use super::style::Theme;

/// An sRGB colour, each channel 0 to 1.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Color {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
}

impl Color {
    /// The colour of a `0xRRGGBB` value.
    pub fn from_hex(hex: u32) -> Self {
        Self {
            red: f64::from((hex >> 16) & 0xFF) / 255.0,
            green: f64::from((hex >> 8) & 0xFF) / 255.0,
            blue: f64::from(hex & 0xFF) / 255.0,
        }
    }

    /// WCAG relative luminance.
    pub fn luminance(&self) -> f64 {
        0.2126 * linear(self.red) + 0.7152 * linear(self.green) + 0.0722 * linear(self.blue)
    }

    /// WCAG contrast ratio, 1 to 21.
    pub fn contrast(&self, other: &Color) -> f64 {
        let own = self.luminance();
        let theirs = other.luminance();
        let lighter = own.max(theirs);
        let darker = own.min(theirs);
        (lighter + 0.05) / (darker + 0.05)
    }

    /// Hue 0 to 1, saturation and lightness 0 to 1.
    pub fn hsl(&self) -> (f64, f64, f64) {
        let high = self.red.max(self.green).max(self.blue);
        let low = self.red.min(self.green).min(self.blue);
        let lightness = (high + low) / 2.0;
        let delta = high - low;
        if delta <= 1e-9 {
            return (0.0, 0.0, lightness);
        }
        let saturation = delta / (1.0 - (2.0 * lightness - 1.0).abs());
        let mut hue = if high == self.red {
            ((self.green - self.blue) / delta) % 6.0
        } else if high == self.green {
            (self.blue - self.red) / delta + 2.0
        } else {
            (self.red - self.green) / delta + 4.0
        };
        hue /= 6.0;
        if hue < 0.0 {
            hue += 1.0;
        }
        (hue, saturation.min(1.0), lightness)
    }

    /// Builds a colour from hue 0 to 1, saturation and lightness 0 to 1.
    pub fn from_hsl(hue: f64, saturation: f64, lightness: f64) -> Self {
        let chroma = (1.0 - (2.0 * lightness - 1.0).abs()) * saturation;
        let sector = hue * 6.0;
        let second = chroma * (1.0 - ((sector % 2.0) - 1.0).abs());
        let (red, green, blue) = match sector {
            s if s < 1.0 => (chroma, second, 0.0),
            s if s < 2.0 => (second, chroma, 0.0),
            s if s < 3.0 => (0.0, chroma, second),
            s if s < 4.0 => (0.0, second, chroma),
            s if s < 5.0 => (second, 0.0, chroma),
            _ => (chroma, 0.0, second),
        };
        let offset = lightness - chroma / 2.0;
        Self {
            red: (red + offset).clamp(0.0, 1.0),
            green: (green + offset).clamp(0.0, 1.0),
            blue: (blue + offset).clamp(0.0, 1.0),
        }
    }

    /// How colourful the colour looks: HSL chroma.
    pub(crate) fn chroma(&self) -> f64 {
        self.red.max(self.green).max(self.blue) - self.red.min(self.green).min(self.blue)
    }
}

/// The colours a clip is painted in. The background runs from `background`
/// at the top to `background_deep` at the bottom; with `backdrop` above zero
/// the blurred artwork is laid over it at that opacity. `ink` is the text,
/// `accent` the visualizer. Mirrored in Rust as
/// `linux/shared/src/lyric_share/palette.rs`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Palette {
    pub background: Color,
    pub background_deep: Color,
    pub ink: Color,
    pub accent: Color,
    pub backdrop: f64,
}

impl Palette {
    pub const WHITE: Color = Color {
        red: 1.0,
        green: 1.0,
        blue: 1.0,
    };
    pub const NEAR_BLACK: Color = Color {
        red: 18.0 / 255.0,
        green: 18.0 / 255.0,
        blue: 18.0 / 255.0,
    };
    /// Below this chroma the artwork is treated as grey and lends no hue.
    pub const GREY_CHROMA: f64 = 0.08;
    pub const FALLBACK: Color = Color {
        red: 58.0 / 255.0,
        green: 58.0 / 255.0,
        blue: 70.0 / 255.0,
    };

    /// Builds a theme's palette from colours sampled across the artwork, a
    /// small downscale is plenty. With no samples the artwork themes fall
    /// back to a neutral slate.
    pub fn make(theme: Theme, samples: &[Color]) -> Self {
        let average = mean(samples).unwrap_or(Self::FALLBACK);
        let vivid = samples
            .iter()
            .enumerate()
            .max_by(|(left_index, left), (right_index, right)| {
                left.chroma()
                    .total_cmp(&right.chroma())
                    .then(right_index.cmp(left_index))
            })
            .map_or(average, |(_, color)| *color);
        let (tone_hue, tone_saturation, _) = vivid.hsl();
        let grey = vivid.chroma() < Self::GREY_CHROMA;
        let accent_saturation = tone_saturation.clamp(0.45, 0.9);
        let accent_on_dark = if grey {
            Color::from_hex(0xF2F2F2)
        } else {
            Color::from_hsl(tone_hue, accent_saturation, 0.64)
        };
        match theme {
            Theme::Artwork => {
                let (base_hue, base_saturation, _) = average.hsl();
                let saturation = base_saturation.min(0.5);
                Self {
                    background: Color::from_hsl(base_hue, saturation, 0.18),
                    background_deep: Color::from_hsl(base_hue, saturation, 0.07),
                    ink: Self::WHITE,
                    accent: accent_on_dark,
                    backdrop: 0.6,
                }
            }
            Theme::Vivid => {
                let saturation = if grey {
                    0.0
                } else {
                    tone_saturation.clamp(0.55, 0.95)
                };
                let background = Color::from_hsl(tone_hue, saturation, 0.46);
                let ink = Self::readable_ink(&background);
                Self {
                    background,
                    background_deep: Color::from_hsl(Self::deep_hue(tone_hue), saturation, 0.32),
                    ink,
                    accent: ink,
                    backdrop: 0.0,
                }
            }
            Theme::Dark => Self {
                background: Color::from_hex(0x141416),
                background_deep: Color::from_hex(0x000000),
                ink: Self::WHITE,
                accent: accent_on_dark,
                backdrop: 0.0,
            },
            Theme::Light => {
                let accent = if grey {
                    Self::NEAR_BLACK
                } else {
                    Color::from_hsl(tone_hue, accent_saturation, 0.36)
                };
                Self {
                    background: Color::from_hex(0xF5F1E8),
                    background_deep: Color::from_hex(0xE7E0D2),
                    ink: Self::NEAR_BLACK,
                    accent,
                    backdrop: 0.0,
                }
            }
        }
    }

    /// The vivid gradient's foot turns a little toward red, so a yellow
    /// deepens into amber rather than olive.
    pub fn deep_hue(hue: f64) -> f64 {
        let turned = hue - 0.04;
        if turned < 0.0 {
            turned + 1.0
        } else {
            turned
        }
    }

    /// White or near black, whichever reads better on `background`.
    pub fn readable_ink(background: &Color) -> Color {
        if background.contrast(&Self::WHITE) >= background.contrast(&Self::NEAR_BLACK) {
            Self::WHITE
        } else {
            Self::NEAR_BLACK
        }
    }
}

/// WCAG's linearisation of one sRGB channel.
fn linear(channel: f64) -> f64 {
    if channel <= 0.04045 {
        channel / 12.92
    } else {
        ((channel + 0.055) / 1.055).powf(2.4)
    }
}

/// The channel-wise mean of the samples, or `None` when there are none.
fn mean(samples: &[Color]) -> Option<Color> {
    if samples.is_empty() {
        return None;
    }
    let count = samples.len() as f64;
    Some(Color {
        red: samples.iter().fold(0.0, |sum, color| sum + color.red) / count,
        green: samples.iter().fold(0.0, |sum, color| sum + color.green) / count,
        blue: samples.iter().fold(0.0, |sum, color| sum + color.blue) / count,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_close(actual: f64, expected: f64) {
        assert!((actual - expected).abs() < 1e-9, "{actual} != {expected}");
    }

    #[test]
    fn palettes_read_on_their_backgrounds() {
        let samples = [
            Color::from_hex(0x203040),
            Color::from_hex(0xE04020),
            Color::from_hex(0x102030),
            Color::from_hex(0x404850),
        ];
        for theme in Theme::ALL {
            let palette = Palette::make(theme, &samples);
            assert!(palette.ink.contrast(&palette.background) > 4.5, "{theme:?}");
        }
        let artwork = Palette::make(Theme::Artwork, &samples);
        assert_close(artwork.backdrop, 0.6);
        assert_eq!(artwork.ink, Palette::WHITE);
        assert_close(artwork.accent.hsl().0, Color::from_hex(0xE04020).hsl().0);
        assert_close(artwork.accent.hsl().2, 0.64);
        assert_close(artwork.background.hsl().2, 0.18);
        let vivid = Palette::make(Theme::Vivid, &samples);
        assert_eq!(vivid.accent, vivid.ink);
        assert_close(vivid.backdrop, 0.0);
        assert_close(vivid.background_deep.hsl().2, 0.32);
        assert_close(Palette::deep_hue(0.02), 0.98);
        assert_close(Palette::deep_hue(0.5), 0.46);
        assert_eq!(
            Palette::make(Theme::Light, &samples).ink,
            Palette::NEAR_BLACK
        );
        let grey = Palette::make(Theme::Dark, &[Color::from_hex(0x808080)]);
        assert_eq!(grey.accent, Color::from_hex(0xF2F2F2));
        let empty = Palette::make(Theme::Artwork, &[]);
        assert_close(empty.background.hsl().0, Palette::FALLBACK.hsl().0);
    }

    #[test]
    fn colour_arithmetic() {
        assert_close(Palette::WHITE.contrast(&Color::from_hex(0x000000)), 21.0);
        assert_close(Color::from_hex(0xFF0000).hsl().0, 0.0);
        assert_close(Color::from_hex(0x00FF00).hsl().0, 1.0 / 3.0);
        assert_close(Color::from_hex(0xFF00FF).hsl().0, 5.0 / 6.0);
        let round = Color::from_hsl(0.58, 0.6, 0.4);
        let (hue, saturation, lightness) = round.hsl();
        let back = Color::from_hsl(hue, saturation, lightness);
        assert_close(back.red, round.red);
        assert_close(back.blue, round.blue);
        assert_eq!(
            Palette::readable_ink(&Color::from_hex(0xFFE066)),
            Palette::NEAR_BLACK
        );
        assert_eq!(
            Palette::readable_ink(&Color::from_hex(0x2040A0)),
            Palette::WHITE
        );
    }
}
