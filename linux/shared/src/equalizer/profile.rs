//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Equalizer/EqualizerProfile.swift`.
//!
//! A profile is either a graphic curve, the ten gains a person placed at the
//! ISO centres, or a parametric list of filters. Graphic filter gains are
//! derived by `GraphicSolver` and never stored, so presets stay numbers a human
//! can read. The JSON keys match Swift's Codable output, so a profile saved by
//! one client loads on the other.

use super::biquad::FilterType;
use super::graphic::GraphicSolver;
use super::headroom::Headroom;
use serde::{Deserialize, Serialize};
use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};

/// One filter as a person sees it: its shape, where it sits, how strong and how
/// wide it is, and whether it is switched on.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EqualizerBand {
    #[serde(rename = "type")]
    pub filter_type: FilterType,
    pub frequency: f64,
    pub gain: f64,
    pub q: f64,
    pub is_enabled: bool,
}

impl EqualizerBand {
    pub const FREQUENCY_MIN: f64 = 20.0;
    pub const FREQUENCY_MAX: f64 = 20_000.0;
    pub const GAIN_MIN: f64 = -12.0;
    pub const GAIN_MAX: f64 = 12.0;
    pub const Q_MIN: f64 = 0.3;
    pub const Q_MAX: f64 = 10.0;
    pub const MAXIMUM_PER_PROFILE: usize = 10;

    /// A band with the shape's default Q when `q` is `None`.
    pub fn new(
        filter_type: FilterType,
        frequency: f64,
        gain: f64,
        q: Option<f64>,
        is_enabled: bool,
    ) -> Self {
        Self {
            filter_type,
            frequency,
            gain,
            q: q.unwrap_or(filter_type.default_q()),
            is_enabled,
        }
    }

    /// The band with every value forced into the range the equalizer allows.
    pub fn clamped(&self) -> Self {
        Self {
            filter_type: self.filter_type,
            frequency: Self::forced(self.frequency, Self::FREQUENCY_MIN, Self::FREQUENCY_MAX, 1_000.0),
            gain: if self.filter_type.has_gain() {
                Self::forced(self.gain, Self::GAIN_MIN, Self::GAIN_MAX, 0.0)
            } else {
                0.0
            },
            q: Self::forced(self.q, Self::Q_MIN, Self::Q_MAX, self.filter_type.default_q()),
            is_enabled: self.is_enabled,
        }
    }

    /// `value` inside `low..=high`, or `fallback` when it is not a number at all:
    /// the Swift client has to guard against NaN here, and the answer must match.
    fn forced(value: f64, low: f64, high: f64, fallback: f64) -> f64 {
        if value.is_finite() {
            value.max(low).min(high)
        } else {
            fallback
        }
    }
}

/// Whether a profile is read off a ten-slider curve or a filter list.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EqualizerKind {
    Graphic,
    Parametric,
}

/// A named equalizer curve. The preamp is either the automatic headroom or the
/// person's own value.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EqualizerProfile {
    pub id: String,
    pub name: String,
    pub kind: EqualizerKind,
    pub targets: Vec<f64>,
    pub bands: Vec<EqualizerBand>,
    pub is_auto_preamp: bool,
    pub manual_preamp: f64,
}

impl EqualizerProfile {
    pub const FLAT_ID: &'static str = "builtin.flat";
    pub const PREAMP_MIN: f64 = -24.0;
    pub const PREAMP_MAX: f64 = 6.0;

    /// A graphic profile with the automatic preamp.
    pub fn graphic(id: impl Into<String>, name: impl Into<String>, targets: Vec<f64>) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            kind: EqualizerKind::Graphic,
            targets,
            bands: Vec::new(),
            is_auto_preamp: true,
            manual_preamp: 0.0,
        }
    }

    /// A parametric profile with the automatic preamp and the zero targets a
    /// fresh profile carries.
    pub fn parametric(
        id: impl Into<String>,
        name: impl Into<String>,
        bands: Vec<EqualizerBand>,
    ) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            kind: EqualizerKind::Parametric,
            targets: vec![0.0; GraphicSolver::CENTRES.len()],
            bands,
            is_auto_preamp: true,
            manual_preamp: 0.0,
        }
    }

    pub fn is_built_in(&self) -> bool {
        self.id.starts_with("builtin.")
    }

    /// The filters the DSP runs and the curve is drawn from.
    pub fn resolved_bands(&self) -> Vec<EqualizerBand> {
        match self.kind {
            EqualizerKind::Graphic => GraphicSolver::bands_for_targets(&self.targets),
            EqualizerKind::Parametric => self.bands.iter().map(EqualizerBand::clamped).collect(),
        }
    }

    /// The preamp in decibels: the automatic headroom, or the person's own.
    pub fn preamp(&self) -> f64 {
        if self.is_auto_preamp {
            Headroom::auto_preamp(&self.resolved_bands())
        } else {
            self.manual_preamp
                .max(Self::PREAMP_MIN)
                .min(Self::PREAMP_MAX)
        }
    }

    /// The preamp for already resolved bands, so the caller does not solve twice.
    pub fn preamp_for(&self, resolved: &[EqualizerBand]) -> f64 {
        if self.is_auto_preamp {
            Headroom::auto_preamp(resolved)
        } else {
            self.manual_preamp
                .max(Self::PREAMP_MIN)
                .min(Self::PREAMP_MAX)
        }
    }

    /// True when the stage would change nothing: every filter flat and no preamp.
    pub fn is_flat(&self) -> bool {
        let resolved = self.resolved_bands();
        let flat_bands = resolved.iter().all(|band| {
            !band.is_enabled
                || (band.filter_type.has_gain()
                    && band.gain.abs() < 0.05
                    && band.filter_type != FilterType::HighPass
                    && band.filter_type != FilterType::LowPass)
        });
        flat_bands && self.preamp_for(&resolved).abs() < 0.05
    }
}

/// A fresh id shaped like the UUID strings Swift gives a profile it creates, so
/// a copy made on Linux and one made on a Mac look alike in a shared file.
pub fn new_id() -> String {
    let high = RandomState::new().build_hasher().finish();
    let low = RandomState::new().build_hasher().finish();
    let hex = format!("{high:016x}{low:016x}");
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamping_turns_a_nan_band_into_a_usable_one() {
        let band = EqualizerBand::new(FilterType::Bell, f64::NAN, f64::INFINITY, Some(f64::NAN), true).clamped();
        assert!(band.frequency.is_finite() && band.gain.is_finite() && band.q.is_finite());
        assert_eq!(band.gain, 0.0);
    }

    #[test]
    fn a_band_json_uses_the_swift_keys() {
        let band = EqualizerBand::new(FilterType::LowShelf, 120.0, -3.0, None, true);
        let json = serde_json::to_string(&band).unwrap();
        assert_eq!(
            json,
            r#"{"type":"lowShelf","frequency":120.0,"gain":-3.0,"q":0.71,"isEnabled":true}"#
        );
    }

    #[test]
    fn a_profile_json_uses_the_swift_keys() {
        let profile = EqualizerProfile::graphic("builtin.rock", "Rock", vec![1.0; 10]);
        let value: serde_json::Value = serde_json::to_value(&profile).unwrap();
        assert_eq!(value["kind"], "graphic");
        assert_eq!(value["isAutoPreamp"], true);
        assert_eq!(value["manualPreamp"], 0.0);
        assert_eq!(value["bands"], serde_json::json!([]));
    }
}
