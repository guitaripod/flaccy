//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Equalizer/Headroom.swift`.
//!
//! How much to turn the signal down so the equalizer's boosts cannot clip. The
//! preamp is minus the peak of the summed response, rounded up to the next 0.1
//! dB. The summed curve is what is measured, not the sum of the band gains:
//! narrow bands that do not overlap would otherwise overstate the peak. A coarse
//! sweep finds where the peaks are and each is then refined, because a bell with
//! a high Q can sit between two sweep points and be a quarter of a decibel taller
//! than either.

use super::biquad::{BiquadMath, Coefficients};
use super::profile::EqualizerBand;

pub struct Headroom;

impl Headroom {
    const SWEEP_POINTS: usize = 400;
    const NEGLIGIBLE_BOOST: f64 = 0.05;
    const REFINEMENT_WINDOW: f64 = 1.0;
    const REFINEMENT_STEPS: usize = 40;

    /// The largest boost anywhere between 20 Hz and 20 kHz, never below 0 dB.
    pub fn peak_boost(bands: &[EqualizerBand]) -> f64 {
        let rate = BiquadMath::REFERENCE_SAMPLE_RATE;
        let compiled: Vec<Coefficients> = bands
            .iter()
            .filter(|band| band.is_enabled)
            .map(|band| BiquadMath::coefficients_for(band, rate))
            .collect();
        if compiled.is_empty() {
            return 0.0;
        }

        let level = |f: f64| {
            compiled
                .iter()
                .fold(0.0, |acc, c| acc + BiquadMath::magnitude_decibels(*c, f, rate))
        };
        let frequencies = BiquadMath::log_frequencies(Self::SWEEP_POINTS);
        let levels: Vec<f64> = frequencies.iter().map(|&f| level(f)).collect();
        let mut peak = levels
            .iter()
            .copied()
            .fold(f64::NEG_INFINITY, f64::max)
            .max(0.0);

        for index in 0..levels.len() {
            if levels[index] < peak - Self::REFINEMENT_WINDOW {
                continue;
            }
            let before = if index > 0 {
                levels[index - 1]
            } else {
                f64::NEG_INFINITY
            };
            let after = if index < levels.len() - 1 {
                levels[index + 1]
            } else {
                f64::NEG_INFINITY
            };
            if !(levels[index] >= before && levels[index] >= after) {
                continue;
            }
            let low = frequencies[index.saturating_sub(1)];
            let high = frequencies[(index + 1).min(frequencies.len() - 1)];
            peak = peak.max(Self::refined_peak(low, high, &level));
        }
        peak
    }

    /// The preamp in decibels for `bands`: zero when the curve never boosts
    /// audibly, otherwise minus the peak rounded up to the next 0.1 dB.
    pub fn auto_preamp(bands: &[EqualizerBand]) -> f64 {
        let peak = Self::peak_boost(bands);
        if peak < Self::NEGLIGIBLE_BOOST {
            return 0.0;
        }
        let rounded = (peak * 10.0 - 1e-6).ceil() / 10.0;
        if rounded <= 0.0 {
            0.0
        } else {
            -rounded
        }
    }

    /// Ternary search for the highest level between two sweep points, in log
    /// frequency.
    fn refined_peak(low: f64, high: f64, level: &impl Fn(f64) -> f64) -> f64 {
        let mut a = low.ln();
        let mut b = high.ln();
        let mut best = level(low).max(level(high));
        for _ in 0..Self::REFINEMENT_STEPS {
            let m1 = a + (b - a) / 3.0;
            let m2 = b - (b - a) / 3.0;
            let l1 = level(m1.exp());
            let l2 = level(m2.exp());
            best = best.max(l1).max(l2);
            if l1 < l2 {
                a = m1;
            } else {
                b = m2;
            }
        }
        best
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::equalizer::presets::EqualizerPresets;
    use crate::equalizer::test_support::Lcg;
    use crate::equalizer::biquad::FilterType;

    #[test]
    fn auto_preamp_turns_down_by_the_peak_of_the_summed_curve() {
        let preamp = |key: &str| EqualizerPresets::profile_for_key(key).unwrap().preamp();
        assert!((preamp("bassBoost") - -6.1).abs() <= 1e-9);
        assert!((preamp("rock") - -4.1).abs() <= 1e-9);
        assert!((preamp("electronic") - -5.1).abs() <= 1e-9);
    }

    #[test]
    fn a_curve_that_only_cuts_is_not_turned_down() {
        for key in ["bassReducer", "trebleReducer", "soften"] {
            let preamp = EqualizerPresets::profile_for_key(key).unwrap().preamp();
            assert_eq!(preamp, 0.0, "{key}");
        }
    }

    #[test]
    fn auto_preamp_never_lets_any_frequency_exceed_zero() {
        let mut generator = Lcg::new(0x5EED_0001);
        let shapes = [FilterType::Bell, FilterType::LowShelf, FilterType::HighShelf];
        for _ in 0..40 {
            let count = 1 + generator.below(6);
            let bands: Vec<EqualizerBand> = (0..count)
                .map(|_| {
                    let shape = shapes[generator.below(shapes.len())];
                    EqualizerBand::new(
                        shape,
                        generator.range(40.0, 16_000.0),
                        generator.range(-12.0, 12.0),
                        Some(generator.range(0.4, 6.0)),
                        true,
                    )
                })
                .collect();
            let preamp = Headroom::auto_preamp(&bands);
            for f in BiquadMath::log_frequencies(600) {
                let heard = BiquadMath::response_decibels(&bands, f) + preamp;
                assert!(heard <= 0.06, "{heard} at {f} Hz");
            }
        }
    }
}
