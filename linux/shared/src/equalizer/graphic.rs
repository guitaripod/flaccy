//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Equalizer/GraphicSolver.swift`.
//!
//! A classic graphic equalizer sums ten overlapping bells, so a slider set to
//! +6 dB is heard at roughly +7 dB where its neighbours reinforce it. Here the
//! ten filter gains are solved so the summed response meets every target at its
//! centre: a 10 by 10 interaction matrix solved by elimination, refined by three
//! Newton passes against the exact response.

use super::biquad::{BiquadMath, FilterType};
use super::plot::EqualizerPlot;
use super::profile::EqualizerBand;
use std::sync::OnceLock;

/// The ten-band graphic equalizer, solved so the curve passes through the points
/// a person places.
pub struct GraphicSolver;

impl GraphicSolver {
    /// ISO third-octave-spaced centres, one octave apart.
    pub const CENTRES: [f64; 10] = [
        32.0, 64.0, 125.0, 250.0, 500.0, 1_000.0, 2_000.0, 4_000.0, 8_000.0, 16_000.0,
    ];

    /// The Q whose bandwidth is one octave, so adjacent bells sum smoothly.
    pub const Q: f64 = 1.41;

    /// The most a single solved filter may be pushed, so an extreme alternating
    /// curve cannot ask for an unreasonable boost.
    pub const FILTER_GAIN_LIMIT: f64 = 18.0;

    const PROBE_GAIN: f64 = 6.0;
    const REFINEMENT_PASSES: usize = 3;

    fn interaction() -> &'static [Vec<f64>] {
        static INTERACTION: OnceLock<Vec<Vec<f64>>> = OnceLock::new();
        INTERACTION.get_or_init(|| {
            let rate = BiquadMath::REFERENCE_SAMPLE_RATE;
            Self::CENTRES
                .iter()
                .map(|&probe| {
                    Self::CENTRES
                        .iter()
                        .map(|&centre| {
                            let c = BiquadMath::coefficients(
                                FilterType::Bell,
                                centre,
                                Self::PROBE_GAIN,
                                Self::Q,
                                rate,
                            );
                            BiquadMath::magnitude_decibels(c, probe, rate) / Self::PROBE_GAIN
                        })
                        .collect()
                })
                .collect()
        })
    }

    /// The ten bells, at their centres, whose summed response meets `targets`.
    /// Missing targets count as zero.
    pub fn bands_for_targets(targets: &[f64]) -> Vec<EqualizerBand> {
        let padded: Vec<f64> = (0..Self::CENTRES.len())
            .map(|i| targets.get(i).copied().unwrap_or(0.0))
            .collect();
        let gains = Self::solve(&padded);
        Self::CENTRES
            .iter()
            .zip(gains)
            .map(|(&centre, gain)| {
                EqualizerBand::new(FilterType::Bell, centre, gain, Some(Self::Q), true)
            })
            .collect()
    }

    /// The ten targets that best stand in for an arbitrary curve: its response
    /// at each centre, settled onto half decibels and held inside the slider range.
    pub fn targets_approximating(bands: &[EqualizerBand]) -> Vec<f64> {
        Self::CENTRES
            .iter()
            .map(|&centre| {
                let heard = BiquadMath::response_decibels(bands, centre);
                let stepped = (heard / EqualizerPlot::GAIN_STEP).round() * EqualizerPlot::GAIN_STEP;
                stepped
                    .max(EqualizerBand::GAIN_MIN)
                    .min(EqualizerBand::GAIN_MAX)
            })
            .collect()
    }

    /// The gains of the ten centre bells that sum to `targets`, each clamped to
    /// the filter gain limit.
    pub fn solve(targets: &[f64]) -> Vec<f64> {
        let mut x = Self::solve_linear(Self::interaction(), targets);
        for _ in 0..Self::REFINEMENT_PASSES {
            let bands: Vec<EqualizerBand> = Self::CENTRES
                .iter()
                .zip(x.iter())
                .map(|(&centre, &gain)| {
                    EqualizerBand::new(FilterType::Bell, centre, gain, Some(Self::Q), true)
                })
                .collect();
            let residual: Vec<f64> = Self::CENTRES
                .iter()
                .zip(targets.iter())
                .map(|(&centre, &target)| target - BiquadMath::response_decibels(&bands, centre))
                .collect();
            let step = Self::solve_linear(Self::interaction(), &residual);
            x = x.iter().zip(step.iter()).map(|(a, b)| a + b).collect();
        }
        x.iter()
            .map(|value| value.max(-Self::FILTER_GAIN_LIMIT).min(Self::FILTER_GAIN_LIMIT))
            .collect()
    }

    /// Gaussian elimination with partial pivoting on the augmented system
    /// `[a | b]`, followed by back substitution.
    fn solve_linear(a: &[Vec<f64>], b: &[f64]) -> Vec<f64> {
        let n = b.len();
        let mut m: Vec<Vec<f64>> = (0..n)
            .map(|row| {
                let mut augmented = a[row].clone();
                augmented.push(b[row]);
                augmented
            })
            .collect();
        for column in 0..n {
            let mut pivot = column;
            for row in (column + 1)..n {
                if m[row][column].abs() > m[pivot][column].abs() {
                    pivot = row;
                }
            }
            m.swap(column, pivot);
            let pivot_row = m[column].clone();
            for row in (column + 1)..n {
                let factor = m[row][column] / m[column][column];
                for k in column..=n {
                    m[row][k] -= factor * pivot_row[k];
                }
            }
        }
        let mut x = vec![0.0; n];
        for row in (0..n).rev() {
            let mut sum = m[row][n];
            for k in (row + 1)..n {
                sum -= m[row][k] * x[k];
            }
            x[row] = sum / m[row][row];
        }
        x
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::equalizer::presets::EqualizerPresets;

    #[test]
    fn every_preset_is_met_exactly_at_the_centres() {
        for preset in EqualizerPresets::all() {
            let bands = preset.resolved_bands();
            for (&centre, &target) in GraphicSolver::CENTRES.iter().zip(preset.targets.iter()) {
                let heard = BiquadMath::response_decibels(&bands, centre);
                assert!(
                    (heard - target).abs() <= 0.01,
                    "{} at {} Hz: {} != {}",
                    preset.name,
                    centre,
                    heard,
                    target
                );
            }
        }
    }

    #[test]
    fn no_solved_filter_asks_for_an_unreasonable_boost() {
        for preset in EqualizerPresets::all() {
            let worst = preset
                .resolved_bands()
                .iter()
                .map(|band| band.gain.abs())
                .fold(0.0, f64::max);
            assert!(worst < 8.0, "{}: {}", preset.name, worst);
        }
    }

    #[test]
    fn an_alternating_curve_stays_within_the_filter_limit() {
        let zigzag = [12.0, -12.0, 12.0, -12.0, 12.0, -12.0, 12.0, -12.0, 12.0, -12.0];
        let worst = GraphicSolver::bands_for_targets(&zigzag)
            .iter()
            .map(|band| band.gain.abs())
            .fold(0.0, f64::max);
        assert!(worst <= GraphicSolver::FILTER_GAIN_LIMIT, "{worst}");
    }

    #[test]
    fn flat_solves_to_nothing() {
        assert!(GraphicSolver::solve(&[0.0; 10])
            .iter()
            .all(|value| value.abs() < 1e-9));
        assert!(EqualizerPresets::flat().is_flat());
    }

    #[test]
    fn approximating_a_solved_preset_returns_its_targets() {
        let rock = EqualizerPresets::profile_for_key("rock").unwrap();
        let approximated = GraphicSolver::targets_approximating(&rock.resolved_bands());
        assert_eq!(approximated, rock.targets);
    }

    #[test]
    fn approximating_a_bell_past_the_slider_range_clamps_to_twelve() {
        let bell = EqualizerBand::new(FilterType::Bell, 1_000.0, 20.0, None, true);
        let approximated = GraphicSolver::targets_approximating(&[bell]);
        assert_eq!(approximated[5], 12.0);
        assert!(approximated
            .iter()
            .all(|&target| (-12.0..=12.0).contains(&target)));
    }
}
