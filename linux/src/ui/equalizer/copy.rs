//! Every word the equalizer says, in the order and wording of
//! `Features/Equalizer/EqualizerCopy.swift`, plus the number formatting and the lenient
//! parsing of what a person types into a field.

use flaccy_shared::equalizer::biquad::FilterType;
use flaccy_shared::equalizer::profile::EqualizerKind;

pub const TITLE: &str = "Equalizer";
pub const AUTOEQ_URL: &str = "https://autoeq.app";
pub const KEYS_HINT: &str =
    "← → select band · ↑ ↓ ±0.5 dB · Shift ±2 · Alt ±0.1 · 0 reset · Ctrl+Z undo · Ctrl+E show or hide";
pub const SIMPLE_HINT: &str = "Drag a point, or type a value. The curve passes through every point.";
pub const ADVANCED_HINT: &str =
    "Drag a node · scroll over it to change Q · double-click empty space to add a band";

/// What the status line reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Off,
    Flat,
    Processing,
    Comparing,
}

pub fn status(status: Status) -> &'static str {
    match status {
        Status::Off => "Off · bit-perfect",
        Status::Flat => "Flat · bit-perfect",
        Status::Processing => "Processing · 32-bit float",
        Status::Comparing => "Hearing original · level-matched",
    }
}

pub fn type_name(filter_type: FilterType) -> &'static str {
    match filter_type {
        FilterType::Bell => "Bell",
        FilterType::LowShelf => "Low shelf",
        FilterType::HighShelf => "High shelf",
        FilterType::HighPass => "High-pass",
        FilterType::LowPass => "Low-pass",
    }
}

/// The filter types in the order the type menu lists them.
pub const FILTER_TYPES: [FilterType; 5] = [
    FilterType::Bell,
    FilterType::LowShelf,
    FilterType::HighShelf,
    FilterType::HighPass,
    FilterType::LowPass,
];

pub fn preset_subtitle(key: &str) -> &'static str {
    match key {
        "flat" => "No processing, bit-perfect",
        "bassBoost" => "A fuller low end",
        "bassReducer" => "Tighter, less boom",
        "trebleBoost" => "More air and sparkle",
        "trebleReducer" => "Less sizzle on bright records",
        "vocal" => "Voices step forward",
        "spokenWord" => "Podcasts and audiobooks",
        "soften" => "Tames harsh highs",
        "loudness" => "Fuller sound at low volume",
        "acoustic" => "Natural strings and room",
        "classical" => "Open and airy",
        "rock" => "Punch and bite",
        "electronic" => "Deep lows, bright top",
        "hipHop" => "Heavy low end, clear vocals",
        "jazz" => "Warm and smooth",
        "pop" => "Present midrange",
        _ => "",
    }
}

/// What a person's own profile is described as in the presets list.
pub fn kind_subtitle(kind: EqualizerKind, band_count: usize) -> String {
    match kind {
        EqualizerKind::Graphic => "Simple".to_string(),
        EqualizerKind::Parametric => format!("Advanced · {band_count} bands"),
    }
}

/// A gain as the screens write it: one decimal, an explicit sign, a true minus.
pub fn decibels(value: f64) -> String {
    let rounded = (value * 10.0).round() / 10.0;
    if rounded == 0.0 {
        return "0.0".to_string();
    }
    let sign = if rounded > 0.0 { "+" } else { "\u{2212}" };
    format!("{sign}{:.1}", rounded.abs())
}

fn kilo(value: f64) -> String {
    let kilo = value / 1000.0;
    if kilo >= 10.0 || (kilo - kilo.round()).abs() < 0.05 {
        format!("{}", kilo.round() as i64)
    } else {
        format!("{kilo:.1}")
    }
}

pub fn hertz(value: f64) -> String {
    if value >= 1000.0 {
        format!("{} kHz", kilo(value))
    } else {
        format!("{} Hz", value.round() as i64)
    }
}

pub fn short_hertz(value: f64) -> String {
    if value >= 1000.0 {
        format!("{}k", kilo(value))
    } else {
        format!("{}", value.round() as i64)
    }
}

pub fn q(value: f64) -> String {
    format!("{value:.2}")
}

pub fn dropped_filters_warning(count: usize) -> String {
    format!(
        "{count} filters could not be kept: a profile holds up to 10, and Flaccy kept the strongest."
    )
}

/// A number typed into a gain or Q field: an optional sign, a true minus, a
/// trailing `dB` and a comma for the decimal point are all accepted.
pub fn parse_number(text: &str) -> Option<f64> {
    let cleaned = text
        .to_lowercase()
        .replace("db", "")
        .replace('\u{2212}', "-")
        .replace(',', ".");
    let value: f64 = cleaned.trim().parse().ok()?;
    value.is_finite().then_some(value)
}

/// A frequency typed into a field: `250`, `250 Hz`, `1.2k`, `1.2 kHz`.
pub fn parse_frequency(text: &str) -> Option<f64> {
    let lowered = text.to_lowercase().replace("hz", "").replace(',', ".");
    let trimmed = lowered.trim();
    let (digits, factor) = match trimmed.strip_suffix('k') {
        Some(rest) => (rest, 1_000.0),
        None => (trimmed, 1.0),
    };
    let value: f64 = digits.trim().parse().ok()?;
    (value * factor > 0.0 && value.is_finite()).then_some(value * factor)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decibels_carry_a_sign_and_one_decimal() {
        assert_eq!(decibels(3.5), "+3.5");
        assert_eq!(decibels(-1.0), "\u{2212}1.0");
        assert_eq!(decibels(0.04), "0.0");
        assert_eq!(decibels(-0.04), "0.0");
        assert_eq!(decibels(11.96), "+12.0");
    }

    #[test]
    fn frequencies_switch_to_kilohertz_at_a_thousand() {
        assert_eq!(hertz(95.0), "95 Hz");
        assert_eq!(hertz(1000.0), "1 kHz");
        assert_eq!(hertz(3300.0), "3.3 kHz");
        assert_eq!(hertz(12000.0), "12 kHz");
        assert_eq!(short_hertz(32.0), "32");
        assert_eq!(short_hertz(1000.0), "1k");
        assert_eq!(short_hertz(16000.0), "16k");
        assert_eq!(short_hertz(1500.0), "1.5k");
    }

    #[test]
    fn typed_gains_accept_signs_units_and_the_true_minus() {
        assert_eq!(parse_number("+3.5"), Some(3.5));
        assert_eq!(parse_number("-2"), Some(-2.0));
        assert_eq!(parse_number("\u{2212}1.5 dB"), Some(-1.5));
        assert_eq!(parse_number(" 4,5 "), Some(4.5));
        assert_eq!(parse_number("loud"), None);
        assert_eq!(parse_number(""), None);
        assert_eq!(parse_number("inf"), None);
    }

    #[test]
    fn typed_frequencies_accept_hertz_and_kilohertz() {
        assert_eq!(parse_frequency("250"), Some(250.0));
        assert_eq!(parse_frequency("250 Hz"), Some(250.0));
        assert_eq!(parse_frequency("1.2k"), Some(1200.0));
        assert_eq!(parse_frequency("1.2 kHz"), Some(1200.0));
        assert_eq!(parse_frequency("12K"), Some(12000.0));
        assert_eq!(parse_frequency("-5"), None);
        assert_eq!(parse_frequency("k"), None);
        assert_eq!(parse_frequency("fast"), None);
    }

    #[test]
    fn every_built_in_preset_has_a_subtitle() {
        for entry in flaccy_shared::equalizer::presets::EqualizerPresets::ENTRIES {
            assert!(!preset_subtitle(entry.key).is_empty(), "{}", entry.key);
        }
    }

    #[test]
    fn the_status_lines_match_the_apple_copy() {
        assert_eq!(status(Status::Processing), "Processing · 32-bit float");
        assert_eq!(status(Status::Comparing), "Hearing original · level-matched");
    }
}
