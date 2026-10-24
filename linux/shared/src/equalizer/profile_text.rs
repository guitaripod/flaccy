//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Equalizer/EqualizerProfileText.swift`.
//!
//! Equalizer profiles as text: the format Equalizer APO and AutoEq publish, so a
//! headphone correction copied from the web imports as it is and a profile
//! exported here opens in the tools people already use. Reads `Preamp:`,
//! `Filter n: ON PK|LS|LSC|HS|HSC|LP|LPQ|HP|HPQ Fc … Hz Gain … dB Q …` and
//! `GraphicEQ:` point lists. Writes the same lines plus two comment lines of its
//! own that let a graphic profile round-trip exactly. Anything else in the text
//! is ignored, and text with no filters at all is refused whole.

use super::biquad::FilterType;
use super::graphic::GraphicSolver;
use super::headroom::Headroom;
use super::profile::{new_id, EqualizerBand, EqualizerKind, EqualizerProfile};
use std::cmp::Ordering;
use std::collections::HashSet;

/// A parsed profile and how many filters the text carried that it could not keep.
#[derive(Clone, Debug, PartialEq)]
pub struct Parsed {
    pub profile: EqualizerProfile,
    pub dropped_filters: usize,
}

enum FilterResult {
    Band(EqualizerBand),
    Unsupported,
    Nothing,
}

pub struct EqualizerProfileText;

impl EqualizerProfileText {
    const GRAPHIC_COMMENT: &'static str = "# FlaccyGraphic:";
    const NAME_COMMENT: &'static str = "# Flaccy Equalizer:";
    const AUTO_PREAMP_TOLERANCE: f64 = 0.06;

    /// Reads a profile from text, or `None` when the text holds nothing usable.
    pub fn parse(text: &str, fallback_name: &str) -> Option<Parsed> {
        let mut name = fallback_name.to_string();
        let mut preamp: Option<f64> = None;
        let mut filters: Vec<EqualizerBand> = Vec::new();
        let mut dropped_kinds = 0usize;
        let mut graphic_targets: Option<Vec<f64>> = None;
        let mut graphic_points: Vec<(f64, f64)> = Vec::new();

        for raw_line in text.split(is_newline) {
            let line = raw_line.trim();
            if line.is_empty() {
                continue;
            }
            if let Some(rest) = line.strip_prefix(Self::NAME_COMMENT) {
                let value = rest.trim();
                if !value.is_empty() {
                    name = value.to_string();
                }
            } else if let Some(rest) = line.strip_prefix(Self::GRAPHIC_COMMENT) {
                let values: Vec<f64> = rest
                    .split(' ')
                    .filter(|part| !part.is_empty())
                    .filter_map(|part| finite_number(part))
                    .collect();
                if values.len() == GraphicSolver::CENTRES.len() {
                    graphic_targets = Some(values);
                }
            } else if let Some(rest) = strip_prefix_ignoring_case(line, "preamp:") {
                preamp = first_number(rest);
            } else if let Some(rest) = strip_prefix_ignoring_case(line, "graphiceq:") {
                graphic_points = parse_graphic_points(rest);
            } else if strip_prefix_ignoring_case(line, "filter").is_some() {
                match parse_filter(line) {
                    FilterResult::Band(band) => filters.push(band),
                    FilterResult::Unsupported => dropped_kinds += 1,
                    FilterResult::Nothing => {}
                }
            }
        }

        if let Some(targets) = graphic_targets {
            let targets: Vec<f64> = targets.into_iter().map(clamp_gain).collect();
            let profile = with_preamp(
                EqualizerProfile::graphic(new_id(), name, targets),
                preamp,
            );
            return Some(Parsed {
                profile,
                dropped_filters: 0,
            });
        }
        if !filters.is_empty() {
            let total = filters.len();
            let kept = strongest(filters, EqualizerBand::MAXIMUM_PER_PROFILE);
            let dropped = total - kept.len() + dropped_kinds;
            let profile = with_preamp(EqualizerProfile::parametric(new_id(), name, kept), preamp);
            return Some(Parsed {
                profile,
                dropped_filters: dropped,
            });
        }
        if graphic_points.len() >= 2 {
            let targets: Vec<f64> = GraphicSolver::CENTRES
                .iter()
                .map(|&centre| clamp_gain(interpolate(&graphic_points, centre)))
                .collect();
            let profile = with_preamp(EqualizerProfile::graphic(new_id(), name, targets), preamp);
            return Some(Parsed {
                profile,
                dropped_filters: 0,
            });
        }
        None
    }

    /// Writes a profile as text. A graphic profile also carries its targets on a
    /// comment line so it reads back exactly.
    pub fn write(profile: &EqualizerProfile) -> String {
        let resolved = profile.resolved_bands();
        let mut lines = vec![format!("{} {}", Self::NAME_COMMENT, profile.name)];
        if profile.kind == EqualizerKind::Graphic {
            let targets: Vec<String> = profile.targets.iter().map(|&t| format_number(t)).collect();
            lines.push(format!("{} {}", Self::GRAPHIC_COMMENT, targets.join(" ")));
        }
        lines.push(format!(
            "Preamp: {} dB",
            format_number(profile.preamp_for(&resolved))
        ));
        for (index, band) in resolved.iter().enumerate() {
            let state = if band.is_enabled { "ON" } else { "OFF" };
            let mut line = format!(
                "Filter {}: {} {} Fc {} Hz",
                index + 1,
                state,
                token(band.filter_type),
                format_number(band.frequency)
            );
            if band.filter_type.has_gain() {
                line += &format!(" Gain {} dB", format_number(band.gain));
            }
            line += &format!(" Q {}", format_number(band.q));
            lines.push(line);
        }
        lines.join("\n") + "\n"
    }
}

fn is_newline(c: char) -> bool {
    matches!(
        c,
        '\n' | '\r' | '\u{000B}' | '\u{000C}' | '\u{0085}' | '\u{2028}' | '\u{2029}'
    )
}

fn is_separator(c: char) -> bool {
    c == ' ' || c == '\t'
}

fn strip_prefix_ignoring_case<'a>(line: &'a str, prefix: &str) -> Option<&'a str> {
    line.get(..prefix.len())
        .filter(|head| head.eq_ignore_ascii_case(prefix))
        .map(|_| &line[prefix.len()..])
}

fn parse_filter(line: &str) -> FilterResult {
    let Some(colon) = line.find(':') else {
        return FilterResult::Nothing;
    };
    let tokens: Vec<&str> = line[colon + 1..]
        .split(is_separator)
        .filter(|token| !token.is_empty())
        .collect();
    if tokens.len() < 2 {
        return FilterResult::Nothing;
    }
    let first = tokens[0].to_uppercase();
    let enabled = first != "OFF";
    let skip = if first == "ON" || first == "OFF" { 1 } else { 0 };
    let rest = &tokens[skip..];
    let Some(kind) = rest.first().map(|token| token.to_uppercase()) else {
        return FilterResult::Nothing;
    };
    let Some(filter_type) = filter_type_for(&kind) else {
        return FilterResult::Unsupported;
    };

    let mut frequency: Option<f64> = None;
    let mut gain = 0.0;
    let mut q: Option<f64> = None;
    let mut index = 1;
    while index < rest.len() {
        let key = rest[index].to_uppercase();
        let has_value = index + 1 < rest.len();
        if key == "FC" && has_value {
            frequency = finite_number(rest[index + 1]);
            index += 2;
        } else if key == "GAIN" && has_value {
            gain = finite_number(rest[index + 1]).unwrap_or(0.0);
            index += 2;
        } else if key == "Q" && has_value {
            q = finite_number(rest[index + 1]);
            index += 2;
        } else {
            index += 1;
        }
    }
    let Some(frequency) = frequency else {
        return FilterResult::Nothing;
    };
    FilterResult::Band(EqualizerBand::new(filter_type, frequency, gain, q, enabled).clamped())
}

fn filter_type_for(token: &str) -> Option<FilterType> {
    match token {
        "PK" | "PEQ" => Some(FilterType::Bell),
        "LS" | "LSC" | "LSQ" => Some(FilterType::LowShelf),
        "HS" | "HSC" | "HSQ" => Some(FilterType::HighShelf),
        "LP" | "LPQ" => Some(FilterType::LowPass),
        "HP" | "HPQ" => Some(FilterType::HighPass),
        _ => None,
    }
}

fn token(filter_type: FilterType) -> &'static str {
    match filter_type {
        FilterType::Bell => "PK",
        FilterType::LowShelf => "LSC",
        FilterType::HighShelf => "HSC",
        FilterType::HighPass => "HPQ",
        FilterType::LowPass => "LPQ",
    }
}

fn parse_graphic_points(text: &str) -> Vec<(f64, f64)> {
    let mut points: Vec<(f64, f64)> = text
        .split(';')
        .filter_map(|pair| {
            let parts: Vec<&str> = pair
                .split(is_separator)
                .filter(|part| !part.is_empty())
                .collect();
            if parts.len() < 2 {
                return None;
            }
            let frequency = finite_number(parts[0])?;
            let gain = finite_number(parts[1])?;
            Some((frequency, gain))
        })
        .collect();
    points.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(Ordering::Equal));
    points
}

fn interpolate(points: &[(f64, f64)], frequency: f64) -> f64 {
    if frequency <= points[0].0 {
        return points[0].1;
    }
    if let Some(last) = points.last() {
        if frequency >= last.0 {
            return last.1;
        }
    }
    for index in 1..points.len() {
        if frequency <= points[index].0 {
            let (f0, g0) = points[index - 1];
            let (f1, g1) = points[index];
            if !(f1 > f0) {
                return g1;
            }
            let t = (frequency.ln() - f0.ln()) / (f1.ln() - f0.ln());
            return g0 + (g1 - g0) * t;
        }
    }
    0.0
}

fn strongest(filters: Vec<EqualizerBand>, limit: usize) -> Vec<EqualizerBand> {
    if filters.len() <= limit {
        return filters;
    }
    let weight = |band: &EqualizerBand| {
        if band.filter_type.has_gain() {
            band.gain.abs()
        } else {
            EqualizerBand::GAIN_MAX
        }
    };
    let mut order: Vec<usize> = (0..filters.len()).collect();
    order.sort_by(|&a, &b| {
        weight(&filters[b])
            .partial_cmp(&weight(&filters[a]))
            .unwrap_or(Ordering::Equal)
    });
    let keep: HashSet<usize> = order.into_iter().take(limit).collect();
    filters
        .into_iter()
        .enumerate()
        .filter(|(index, _)| keep.contains(index))
        .map(|(_, band)| band)
        .collect()
}

fn with_preamp(profile: EqualizerProfile, preamp: Option<f64>) -> EqualizerProfile {
    let mut result = profile;
    let Some(preamp) = preamp else {
        return result;
    };
    let auto = Headroom::auto_preamp(&result.resolved_bands());
    if (preamp - auto).abs() <= EqualizerProfileText::AUTO_PREAMP_TOLERANCE {
        result.is_auto_preamp = true;
    } else {
        result.is_auto_preamp = false;
        result.manual_preamp = preamp
            .max(EqualizerProfile::PREAMP_MIN)
            .min(EqualizerProfile::PREAMP_MAX);
    }
    result
}

/// A number the text really holds: `str::parse` also accepts "nan" and "inf",
/// which would otherwise travel into the filters and silence the track.
fn finite_number(text: &str) -> Option<f64> {
    text.parse::<f64>().ok().filter(|value| value.is_finite())
}

fn clamp_gain(value: f64) -> f64 {
    value.max(EqualizerBand::GAIN_MIN).min(EqualizerBand::GAIN_MAX)
}

fn first_number(text: &str) -> Option<f64> {
    text.split(is_separator)
        .filter(|part| !part.is_empty())
        .find_map(|part| finite_number(part))
}

/// Two decimals with trailing zeros trimmed, locale independent, so every client
/// writes the same bytes.
fn format_number(value: f64) -> String {
    let mut text = format!("{value:.2}");
    while text.ends_with('0') {
        text.pop();
    }
    if text.ends_with('.') {
        text.pop();
    }
    if text == "-0" {
        "0".to_string()
    } else {
        text
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::equalizer::presets::EqualizerPresets;

    const AUTOEQ_SAMPLE: &str = "Preamp: -6.2 dB
Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
Filter 2: ON PK Fc 210 Hz Gain -2.4 dB Q 0.80
Filter 3: ON PK Fc 3100 Hz Gain 4.1 dB Q 2.10
Filter 4: ON HSC Fc 12000 Hz Gain -1.5 dB Q 0.70";

    #[test]
    fn reads_an_autoeq_profile() {
        let parsed = EqualizerProfileText::parse(AUTOEQ_SAMPLE, "Imported").unwrap();

        assert_eq!(parsed.dropped_filters, 0);
        assert_eq!(parsed.profile.kind, EqualizerKind::Parametric);
        assert_eq!(parsed.profile.name, "Imported");
        let types: Vec<FilterType> = parsed.profile.bands.iter().map(|b| b.filter_type).collect();
        assert_eq!(
            types,
            vec![
                FilterType::LowShelf,
                FilterType::Bell,
                FilterType::Bell,
                FilterType::HighShelf
            ]
        );
        assert_eq!(parsed.profile.bands[2].frequency, 3_100.0);
        assert_eq!(parsed.profile.bands[2].gain, 4.1);
        assert_eq!(parsed.profile.bands[2].q, 2.1);
        assert!(!parsed.profile.is_auto_preamp);
        assert_eq!(parsed.profile.manual_preamp, -6.2);
    }

    #[test]
    fn a_preamp_that_matches_the_automatic_one_stays_automatic() {
        let bands = [EqualizerBand::new(FilterType::Bell, 1_000.0, 6.0, Some(1.0), true)];
        let auto = Headroom::auto_preamp(&bands);
        let text = format!("Preamp: {auto} dB\nFilter 1: ON PK Fc 1000 Hz Gain 6 dB Q 1");

        let parsed = EqualizerProfileText::parse(&text, "x").unwrap();

        assert!(parsed.profile.is_auto_preamp);
    }

    #[test]
    fn a_filter_that_is_off_is_kept_but_disabled() {
        let text = "Filter 1: OFF PK Fc 500 Hz Gain 3 dB Q 1\nFilter 2: ON PK Fc 2000 Hz Gain -3 dB Q 1";

        let parsed = EqualizerProfileText::parse(text, "x").unwrap();

        let enabled: Vec<bool> = parsed.profile.bands.iter().map(|b| b.is_enabled).collect();
        assert_eq!(enabled, vec![false, true]);
    }

    #[test]
    fn pass_filters_carry_no_gain() {
        let text = "Filter 1: ON HPQ Fc 30 Hz Q 0.71\nFilter 2: ON LP Fc 18000 Hz Gain 4 dB Q 0.71";

        let parsed = EqualizerProfileText::parse(text, "x").unwrap();

        let types: Vec<FilterType> = parsed.profile.bands.iter().map(|b| b.filter_type).collect();
        assert_eq!(types, vec![FilterType::HighPass, FilterType::LowPass]);
        let gains: Vec<f64> = parsed.profile.bands.iter().map(|b| b.gain).collect();
        assert_eq!(gains, vec![0.0, 0.0]);
    }

    #[test]
    fn more_than_ten_filters_keeps_the_strongest_and_says_what_it_dropped() {
        let lines: Vec<String> = (1..=12)
            .map(|n| {
                let gain = if n == 3 { 0.1 } else { 4.0 };
                format!("Filter {n}: ON PK Fc {} Hz Gain {gain} dB Q 1", 100 * n)
            })
            .collect();

        let parsed = EqualizerProfileText::parse(&lines.join("\n"), "x").unwrap();

        assert_eq!(parsed.profile.bands.len(), 10);
        assert_eq!(parsed.dropped_filters, 2);
        assert!(!parsed.profile.bands.iter().any(|b| b.frequency == 300.0));
    }

    #[test]
    fn a_filter_of_an_unknown_kind_is_counted_not_imported() {
        let text = "Filter 1: ON PK Fc 500 Hz Gain 3 dB Q 1\nFilter 2: ON NO Fc 50 Hz Q 30";

        let parsed = EqualizerProfileText::parse(text, "x").unwrap();

        assert_eq!(parsed.profile.bands.len(), 1);
        assert_eq!(parsed.dropped_filters, 1);
    }

    #[test]
    fn a_graphic_eq_line_becomes_a_ten_band_profile() {
        let text = "GraphicEQ: 20 0; 100 2; 1000 4; 10000 -2; 20000 -2";

        let parsed = EqualizerProfileText::parse(text, "x").unwrap();

        assert_eq!(parsed.profile.kind, EqualizerKind::Graphic);
        assert_eq!(parsed.profile.targets.len(), 10);
        assert!((parsed.profile.targets[5] - 4.0).abs() <= 1e-9);
        assert!((parsed.profile.targets[9] - -2.0).abs() <= 1.5);
    }

    #[test]
    fn text_with_nothing_to_read_is_refused() {
        assert!(EqualizerProfileText::parse("hello\nworld", "x").is_none());
        assert!(EqualizerProfileText::parse("", "x").is_none());
        assert!(EqualizerProfileText::parse("Preamp: -3 dB", "x").is_none());
    }

    #[test]
    fn numbers_that_are_not_numbers_are_not_read() {
        assert!(EqualizerProfileText::parse("Filter 1: ON PK Fc nan Hz Gain 3 dB Q 1", "x").is_none());
        let parsed =
            EqualizerProfileText::parse("Filter 1: ON PK Fc 1000 Hz Gain inf dB Q 1", "x").unwrap();
        assert_eq!(parsed.profile.bands[0].gain, 0.0);
        assert!(EqualizerProfileText::parse("Preamp: nan dB", "x").is_none());
    }

    #[test]
    fn a_graphic_profile_round_trips_exactly() {
        let original = EqualizerPresets::profile_for_key("rock").unwrap();

        let text = EqualizerProfileText::write(&original);
        let parsed = EqualizerProfileText::parse(&text, "other").unwrap();

        assert_eq!(parsed.profile.kind, EqualizerKind::Graphic);
        assert_eq!(parsed.profile.targets, original.targets);
        assert_eq!(parsed.profile.name, "Rock");
        assert!(parsed.profile.is_auto_preamp);
    }

    #[test]
    fn a_parametric_profile_round_trips_exactly() {
        let original = EqualizerProfile::parametric(
            "test.warm",
            "Warm",
            vec![
                EqualizerBand::new(FilterType::HighPass, 28.0, 0.0, Some(0.71), true),
                EqualizerBand::new(FilterType::LowShelf, 95.0, 3.5, Some(0.71), true),
                EqualizerBand::new(FilterType::Bell, 3_300.0, 2.6, Some(1.4), true),
            ],
        );

        let parsed = EqualizerProfileText::parse(&EqualizerProfileText::write(&original), "x").unwrap();

        assert_eq!(parsed.profile.bands, original.bands);
        assert_eq!(parsed.profile.name, "Warm");
    }

    #[test]
    fn the_written_text_is_the_same_on_every_client() {
        let profile = EqualizerProfile::parametric(
            "test.sample",
            "Sample",
            vec![EqualizerBand::new(FilterType::Bell, 1_000.0, 6.0, Some(1.41), true)],
        );

        assert_eq!(
            EqualizerProfileText::write(&profile),
            "# Flaccy Equalizer: Sample\nPreamp: -6 dB\nFilter 1: ON PK Fc 1000 Hz Gain 6 dB Q 1.41\n"
        );
    }
}
