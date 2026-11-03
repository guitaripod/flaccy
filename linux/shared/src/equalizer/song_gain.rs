//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Equalizer/SongGain.swift`.
//!
//! A song's own volume: how far the player raises or lowers one song, in tenths
//! of a decibel, on every client and every copy of that song. It rides the
//! equalizer's stage rather than a stage of its own: the level is folded into
//! the preamp, so a change glides over the kernel's ramp instead of stepping,
//! and a raised song always runs the peak guard, which is what lets a quiet
//! master come up without clipping.

use super::profile::EqualizerBand;

pub const MAX_TENTHS: i32 = 120;
pub const STEP_TENTHS: i32 = 5;

/// The equalizer stage the element should run for one song.
#[derive(Clone, Debug, PartialEq)]
pub struct Stage {
    pub is_engaged: bool,
    pub bands: Vec<EqualizerBand>,
    pub preamp_db: f64,
    pub peak_guard: bool,
}

pub fn clamped(tenths: i32) -> i32 {
    tenths.clamp(-MAX_TENTHS, MAX_TENTHS)
}

pub fn decibels(tenths: i32) -> f64 {
    f64::from(tenths) / 10.0
}

/// The step nearest to a slider position in decibels.
pub fn snapped(decibels: f64) -> i32 {
    if !decibels.is_finite() {
        return 0;
    }
    let steps = (decibels * 10.0 / f64::from(STEP_TENTHS)).round();
    clamped(steps.clamp(-1_000.0, 1_000.0) as i32 * STEP_TENTHS)
}

/// The level `steps` steps away. A level between two steps, which another
/// client may have set, moves to the neighbouring step in that direction first,
/// so one press never skips past a step.
pub fn stepped(tenths: i32, steps: i32) -> i32 {
    if steps == 0 {
        return clamped(tenths);
    }
    let below = tenths.div_euclid(STEP_TENTHS) * STEP_TENTHS;
    let base = if steps > 0 || below == tenths {
        below
    } else {
        below + STEP_TENTHS
    };
    clamped(base + steps * STEP_TENTHS)
}

/// A level read back from Flaccy Server, which accepts a wider range than these controls offer.
pub fn from_server(value: i64) -> i32 {
    value.clamp(i64::from(-MAX_TENTHS), i64::from(MAX_TENTHS)) as i32
}

/// The equalizer stage with the song's level folded into the preamp. A song at
/// 0 dB leaves the stage exactly as the equalizer has it, so with the
/// equalizer off audio still passes untouched.
pub fn stage(
    is_engaged: bool,
    bands: &[EqualizerBand],
    preamp_db: f64,
    peak_guard: bool,
    tenths: i32,
) -> Stage {
    let level = clamped(tenths);
    Stage {
        is_engaged: is_engaged || level != 0,
        bands: bands.to_vec(),
        preamp_db: preamp_db + decibels(level),
        peak_guard: peak_guard || level > 0,
    }
}

/// The level as people read it: "+3.5 dB", "−2 dB", "0 dB", with a true minus sign.
pub fn label(tenths: i32) -> String {
    let level = clamped(tenths);
    let sign = match level.signum() {
        1 => "+",
        -1 => "\u{2212}",
        _ => "",
    };
    let magnitude = level.unsigned_abs();
    if magnitude % 10 == 0 {
        format!("{sign}{} dB", magnitude / 10)
    } else {
        format!("{sign}{}.{} dB", magnitude / 10, magnitude % 10)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::equalizer::biquad::FilterType;
    use crate::equalizer::kernel::{EqualizerKernel, Plane};

    #[test]
    fn levels_stay_inside_the_controls_range() {
        assert_eq!(clamped(130), 120);
        assert_eq!(clamped(-500), -120);
        assert_eq!(clamped(35), 35);
        assert_eq!(from_server(240), 120);
        assert_eq!(from_server(-240), -120);
        assert_eq!(from_server(-37), -37);
    }

    #[test]
    fn slider_positions_snap_to_half_decibel_steps() {
        assert_eq!(snapped(3.24), 30);
        assert_eq!(snapped(3.26), 35);
        assert_eq!(snapped(-0.2), 0);
        assert_eq!(snapped(-7.8), -80);
        assert_eq!(snapped(40.0), 120);
        assert_eq!(snapped(f64::NAN), 0);
    }

    #[test]
    fn steps_land_on_the_grid_without_skipping_one() {
        assert_eq!(stepped(0, 1), 5);
        assert_eq!(stepped(0, -1), -5);
        assert_eq!(stepped(37, 1), 40);
        assert_eq!(stepped(37, -1), 35);
        assert_eq!(stepped(-37, 1), -35);
        assert_eq!(stepped(-37, -1), -40);
        assert_eq!(stepped(115, 2), 120);
        assert_eq!(stepped(-120, -1), -120);
        assert_eq!(stepped(20, 0), 20);
    }

    #[test]
    fn the_level_folds_into_the_preamp_and_raising_always_guards() {
        let bell = EqualizerBand::new(FilterType::Bell, 1_000.0, 3.0, Some(1.0), true);
        let flat = stage(false, &[], 0.0, false, 0);
        assert_eq!(
            flat,
            Stage {
                is_engaged: false,
                bands: vec![],
                preamp_db: 0.0,
                peak_guard: false
            }
        );

        let raised = stage(false, &[], 0.0, false, 35);
        assert_eq!(
            raised,
            Stage {
                is_engaged: true,
                bands: vec![],
                preamp_db: 3.5,
                peak_guard: true
            }
        );

        let lowered = stage(true, std::slice::from_ref(&bell), -3.1, false, -20);
        assert!(lowered.is_engaged);
        assert_eq!(lowered.bands, vec![bell]);
        assert!((lowered.preamp_db - -5.1).abs() < 1e-12);
        assert!(!lowered.peak_guard);

        assert_eq!(stage(false, &[], 0.0, true, 400).preamp_db, 12.0);
    }

    #[test]
    fn labels_use_a_true_minus() {
        assert_eq!(label(35), "+3.5 dB");
        assert_eq!(label(-20), "\u{2212}2 dB");
        assert_eq!(label(0), "0 dB");
        assert_eq!(label(120), "+12 dB");
        assert_eq!(label(-5), "\u{2212}0.5 dB");
    }

    fn run(stage: &Stage, samples: &mut [f32]) -> EqualizerKernel {
        let mut kernel = EqualizerKernel::new(1, 44_100.0);
        kernel.configure_starting(
            &stage.bands,
            stage.preamp_db,
            stage.is_engaged,
            stage.peak_guard,
            true,
        );
        let frames = samples.len();
        kernel.process(samples, &[Plane { offset: 0, stride: 1 }], frames);
        kernel
    }

    #[test]
    fn a_raised_song_comes_up_by_its_level_in_the_kernel() {
        let mut samples = vec![0.1f32; 512];
        run(&stage(false, &[], 0.0, false, 60), &mut samples);
        let expected = 0.1 * 10f64.powf(6.0 / 20.0);
        assert!((f64::from(samples[511]) - expected).abs() < 1e-5);
    }

    #[test]
    fn a_raised_song_never_leaves_the_kernel_above_full_scale() {
        let mut samples: Vec<f32> = (0..4_096)
            .map(|i| (0.9 * (i as f64 * 2.0 * std::f64::consts::PI * 220.0 / 44_100.0).sin()) as f32)
            .collect();
        let kernel = run(&stage(false, &[], 0.0, false, 120), &mut samples);
        let peak = samples.iter().fold(0f32, |peak, s| peak.max(s.abs()));
        assert!(peak <= 1.0001, "peak {peak}");
        assert!(kernel.guard_reduced());
    }
}
