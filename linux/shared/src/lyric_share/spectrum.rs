//! What a clip's audio looks like frame by frame: the bands and loudness its
//! visualizer draws.
//!
//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/LyricShare/LyricShareSpectrum.swift`.
//! Pure arithmetic on a mono signal, so every client draws the same bars.

use std::f64::consts::PI;

/// The number of frequency bands each frame is split into.
pub const BAND_COUNT: usize = 24;
/// The FFT window length, in samples.
pub const FFT_SIZE: usize = 2048;
/// The lowest frequency a band covers, in hertz.
pub const LOW_HZ: f64 = 50.0;
/// The highest frequency a band covers, in hertz.
pub const HIGH_HZ: f64 = 16_000.0;
/// The quietest band that still shows, relative to a full-scale sine.
pub const BAND_FLOOR_DB: f64 = -60.0;
/// The quietest window that still moves the level.
pub const LEVEL_FLOOR_DB: f64 = -45.0;
/// How much of the way to a louder value a frame goes.
pub const ATTACK: f64 = 0.65;
/// How much of the way to a quieter value a frame goes.
pub const RELEASE: f64 = 0.22;

/// A clip's audio analysed frame by frame: `bands[frame]` holds one value per
/// frequency band and `levels[frame]` the loudness, all 0 to 1.
#[derive(Clone, Debug, PartialEq)]
pub struct Analysis {
    pub bands: Vec<Vec<f32>>,
    pub levels: Vec<f32>,
}

impl Analysis {
    /// A frame's bands, or a quiet row past either end.
    pub fn bands_at(&self, frame: usize) -> Vec<f32> {
        self.bands
            .get(frame)
            .cloned()
            .unwrap_or_else(|| vec![0.0; BAND_COUNT])
    }

    /// A frame's loudness, or silence past either end.
    pub fn level_at(&self, frame: usize) -> f32 {
        self.levels.get(frame).copied().unwrap_or(0.0)
    }
}

/// Analyses `frames` frames at `fps`, each centred on its moment of the
/// signal with zeros beyond either end. A band is the strongest bin it
/// covers, scaled so a full-scale sine reads 0 dB, mapped from the floor
/// to 1; the level is the window's RMS mapped the same way. Both are
/// smoothed frame to frame, quick to rise and slow to fall.
pub fn analyze(mono: &[f32], sample_rate: f64, frames: usize, fps: u32) -> Analysis {
    let size = FFT_SIZE;
    let half = size / 2;
    let window: Vec<f64> = (0..size)
        .map(|index| 0.5 - 0.5 * (2.0 * PI * index as f64 / size as f64).cos())
        .collect();
    let window_sum = window.iter().fold(0.0, |sum, value| sum + value);
    let edges = band_edges(sample_rate);
    let twiddles: Vec<(f64, f64)> = (0..half)
        .map(|index| {
            let angle = -2.0 * PI * index as f64 / size as f64;
            (angle.cos(), angle.sin())
        })
        .collect();
    let mut bands: Vec<Vec<f32>> = Vec::with_capacity(frames);
    let mut levels: Vec<f32> = Vec::with_capacity(frames);
    let mut smoothed_bands = [0.0_f64; BAND_COUNT];
    let mut smoothed_level = 0.0_f64;
    let mut real = vec![0.0_f64; size];
    let mut imaginary = vec![0.0_f64; size];
    for frame in 0..frames {
        let centre = (frame as f64 / f64::from(fps) * sample_rate) as i64;
        let from = centre - half as i64;
        let mut energy = 0.0_f64;
        for (index, (re, im)) in real.iter_mut().zip(imaginary.iter_mut()).enumerate() {
            let at = from + index as i64;
            let sample = if at >= 0 && (at as usize) < mono.len() {
                f64::from(mono[at as usize])
            } else {
                0.0
            };
            energy += sample * sample;
            *re = sample * window[index];
            *im = 0.0;
        }
        transform(&mut real, &mut imaginary, &twiddles);
        for (band, smoothed) in smoothed_bands.iter_mut().enumerate() {
            let mut peak = 0.0_f64;
            for bin in edges[band]..edges[band + 1] {
                let magnitude = (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).sqrt();
                peak = peak.max(magnitude);
            }
            let amplitude = peak * 2.0 / window_sum;
            *smoothed = smooth(*smoothed, scaled(decibels(amplitude), BAND_FLOOR_DB));
        }
        let rms = (energy / size as f64).sqrt();
        smoothed_level = smooth(smoothed_level, scaled(decibels(rms), LEVEL_FLOOR_DB));
        bands.push(smoothed_bands.iter().map(|&value| value as f32).collect());
        levels.push(smoothed_level as f32);
    }
    Analysis { bands, levels }
}

/// The FFT bin each band starts at, plus where the last one ends. Bands
/// are spaced evenly in pitch from `LOW_HZ` to `HIGH_HZ`, each at least one
/// bin wide, none past the Nyquist bin.
pub fn band_edges(sample_rate: f64) -> Vec<usize> {
    let half = FFT_SIZE / 2;
    let mut edges: Vec<usize> = Vec::with_capacity(BAND_COUNT + 1);
    let mut previous = 0_usize;
    for band in 0..=BAND_COUNT {
        let hertz = LOW_HZ * (HIGH_HZ / LOW_HZ).powf(band as f64 / BAND_COUNT as f64);
        let rounded_up = (hertz * FFT_SIZE as f64 / sample_rate).ceil() as usize;
        let lower = if band == 0 { 1 } else { previous + 1 };
        let bin = rounded_up.max(lower).min(half);
        edges.push(bin);
        previous = bin;
    }
    for band in (0..BAND_COUNT).rev() {
        if edges[band] >= edges[band + 1] {
            edges[band] = edges[band + 1].saturating_sub(1);
        }
    }
    edges
}

/// The level in decibels of a linear amplitude, with a floor that keeps silence finite.
fn decibels(amplitude: f64) -> f64 {
    20.0 * (amplitude + 1e-9).log10()
}

/// Maps a decibel value from `floor` (0) to 0 dB (1), clamped.
fn scaled(decibels: f64, floor: f64) -> f64 {
    ((decibels - floor) / -floor).clamp(0.0, 1.0)
}

/// Moves a smoothed value toward `value`: quick to rise, slow to fall.
fn smooth(previous: f64, value: f64) -> f64 {
    previous + (value - previous) * if value > previous { ATTACK } else { RELEASE }
}

/// An in-place iterative radix-2 FFT.
fn transform(real: &mut [f64], imaginary: &mut [f64], twiddles: &[(f64, f64)]) {
    let count = real.len();
    let mut target = 0_usize;
    for index in 0..count {
        if index < target {
            real.swap(index, target);
            imaginary.swap(index, target);
        }
        let mut bit = count >> 1;
        while bit > 0 && target & bit != 0 {
            target ^= bit;
            bit >>= 1;
        }
        target |= bit;
    }
    let mut length = 2;
    while length <= count {
        let step = count / length;
        let half_length = length / 2;
        let mut start = 0;
        while start < count {
            for offset in 0..half_length {
                let (cosine, sine) = twiddles[offset * step];
                let upper = start + offset;
                let lower = upper + half_length;
                let rotated_real = real[lower] * cosine - imaginary[lower] * sine;
                let rotated_imaginary = real[lower] * sine + imaginary[lower] * cosine;
                real[lower] = real[upper] - rotated_real;
                imaginary[lower] = imaginary[upper] - rotated_imaginary;
                real[upper] += rotated_real;
                imaginary[upper] += rotated_imaginary;
            }
            start += length;
        }
        length <<= 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Frame 10's bands and every frame's level for 220 Hz at half scale plus
    /// 3 kHz at a quarter, asserted to the same digits in `spectrum.rs`.
    const PINNED_BANDS: [f32; 24] = [
        0.027948, 0.028650, 0.029360, 0.077009, 0.191920, 0.744638, 0.895245, 0.252928, 0.023902,
        0.016810, 0.011899, 0.005871, 0.000000, 0.000000, 0.002315, 0.007378, 0.612116, 0.789697,
        0.005604, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000,
    ];
    const PINNED_LEVELS: [f32; 12] = [
        0.489352, 0.705210, 0.780663, 0.806069, 0.816061, 0.819461, 0.819648, 0.820813, 0.821125,
        0.820822, 0.821224, 0.821213,
    ];

    fn sine(hertz: f64, amplitude: f64, sample_rate: f64, seconds: f64) -> Vec<f32> {
        let count = (sample_rate * seconds) as usize;
        (0..count)
            .map(|n| (amplitude * (2.0 * PI * hertz * n as f64 / sample_rate).sin()) as f32)
            .collect()
    }

    #[test]
    fn band_edges_rise_one_bin_at_least() {
        let edges = band_edges(48_000.0);
        assert_eq!(edges.len(), 25);
        assert_eq!(edges.first(), Some(&3));
        assert_eq!(edges.last(), Some(&683));
        assert_eq!(&edges[..6], &[3, 4, 5, 6, 7, 8]);
        for index in 1..edges.len() {
            assert!(edges[index] > edges[index - 1]);
        }
        assert_eq!(band_edges(44_100.0).last(), Some(&744));
    }

    #[test]
    fn a_sine_lights_its_own_band() {
        let signal = sine(1000.0, 1.0, 48_000.0, 2.0);
        let analysis = analyze(&signal, 48_000.0, 30, 30);
        assert_eq!(analysis.bands.len(), 30);
        assert_eq!(analysis.levels.len(), 30);
        let settled = &analysis.bands[20];
        let loudest = settled
            .iter()
            .enumerate()
            .max_by(|left, right| left.1.total_cmp(right.1))
            .map(|(index, _)| index);
        assert_eq!(loudest, Some(12));
        assert!(settled[12] > 0.95);
        assert!(settled[2] < 0.2);
        assert!((f64::from(analysis.levels[20]) - 0.9331).abs() < 0.002);
        assert!(analysis.levels[0] < analysis.levels[20]);
    }

    #[test]
    fn silence_is_quiet_and_the_ends_are_quiet() {
        let analysis = analyze(&[0.0; 48_000], 48_000.0, 10, 30);
        assert!(analysis
            .bands
            .iter()
            .all(|row| row.iter().all(|&value| value == 0.0)));
        assert!(analysis.levels.iter().all(|&value| value == 0.0));
        assert_eq!(analysis.bands_at(99), vec![0.0_f32; 24]);
        assert_eq!(analysis.level_at(usize::MAX), 0.0);
        assert_eq!(analyze(&[], 48_000.0, 0, 30).bands.len(), 0);
    }

    #[test]
    fn spectrum_matches_pinned_vectors() {
        let signal: Vec<f32> = sine(220.0, 0.5, 44_100.0, 1.0)
            .into_iter()
            .enumerate()
            .map(|(n, value)| {
                value + (0.25 * (2.0 * PI * 3_000.0 * n as f64 / 44_100.0).sin()) as f32
            })
            .collect();
        let analysis = analyze(&signal, 44_100.0, 12, 30);
        assert_eq!(analysis.bands[10].len(), PINNED_BANDS.len());
        for (value, expected) in analysis.bands[10].iter().zip(PINNED_BANDS.iter()) {
            assert!((value - expected).abs() < 1e-4, "{value} != {expected}");
        }
        for (value, expected) in analysis.levels.iter().zip(PINNED_LEVELS.iter()) {
            assert!((value - expected).abs() < 1e-4, "{value} != {expected}");
        }
    }
}
