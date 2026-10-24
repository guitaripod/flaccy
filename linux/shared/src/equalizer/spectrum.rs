//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Equalizer/SpectrumAnalyzer.swift`.
//!
//! Turns the last 2048 samples the equalizer saw into the 110 log-spaced bins the
//! curve screen draws behind its response, in decibels relative to a full scale
//! sine. A Hann window and a plain radix-2 FFT, written out here rather than taken
//! from a platform library so every client draws the same picture.

use super::profile::EqualizerBand;
use std::f64::consts::PI;

pub struct SpectrumAnalyzer {
    window: Vec<f32>,
    cosines: Vec<f32>,
    sines: Vec<f32>,
    window_gain: f32,
    bin_edges: Vec<usize>,
    real: Vec<f32>,
    imaginary: Vec<f32>,
}

impl SpectrumAnalyzer {
    pub const WINDOW_SIZE: usize = 2_048;
    pub const BIN_COUNT: usize = 110;
    pub const FLOOR_DECIBELS: f32 = -96.0;

    /// An analyzer for audio at `sample_rate`, with its window, twiddle tables and
    /// bin edges computed up front.
    pub fn new(sample_rate: f64) -> Self {
        let n = Self::WINDOW_SIZE;
        let mut window = vec![0.0f32; n];
        let mut sum = 0.0f32;
        for (i, slot) in window.iter_mut().enumerate() {
            let w = (0.5 - 0.5 * (2.0 * PI * i as f64 / n as f64).cos()) as f32;
            *slot = w;
            sum += w;
        }
        let cosines: Vec<f32> = (0..n / 2)
            .map(|k| (-2.0 * PI * k as f64 / n as f64).cos() as f32)
            .collect();
        let sines: Vec<f32> = (0..n / 2)
            .map(|k| (-2.0 * PI * k as f64 / n as f64).sin() as f32)
            .collect();

        let nyquist = sample_rate / 2.0;
        let low = EqualizerBand::FREQUENCY_MIN;
        let high = EqualizerBand::FREQUENCY_MAX.min(nyquist * 0.98);
        let bin_edges: Vec<usize> = (0..=Self::BIN_COUNT)
            .map(|index| {
                let f = low * (high / low).powf(index as f64 / Self::BIN_COUNT as f64);
                let line = (f / sample_rate * n as f64).round() as i64;
                line.max(1).min(n as i64 / 2 - 1) as usize
            })
            .collect();

        Self {
            window,
            cosines,
            sines,
            window_gain: 2.0 / sum,
            bin_edges,
            real: vec![0.0f32; n],
            imaginary: vec![0.0f32; n],
        }
    }

    /// Decibel level of each log-spaced bin for the first `WINDOW_SIZE` samples.
    /// A bin narrower than one FFT line reads the line it falls on.
    ///
    /// Panics when `samples` holds fewer than `WINDOW_SIZE` samples.
    pub fn analyze(&mut self, samples: &[f32]) -> Vec<f32> {
        let n = Self::WINDOW_SIZE;
        let samples = &samples[..n];
        for i in 0..n {
            self.real[i] = samples[i] * self.window[i];
            self.imaginary[i] = 0.0;
        }
        self.fft();

        let mut lines = vec![Self::FLOOR_DECIBELS; n / 2];
        for i in 1..(n / 2) {
            let magnitude = (self.real[i] * self.real[i] + self.imaginary[i] * self.imaginary[i])
                .sqrt()
                * self.window_gain;
            lines[i] = (20.0 * magnitude.max(1e-9).log10()).max(Self::FLOOR_DECIBELS);
        }

        let mut bins = vec![Self::FLOOR_DECIBELS; Self::BIN_COUNT];
        for (bin, slot) in bins.iter_mut().enumerate() {
            let start = self.bin_edges[bin];
            let end = self.bin_edges[bin + 1].max(start + 1);
            let mut peak = Self::FLOOR_DECIBELS;
            for &level in &lines[start..end.min(n / 2)] {
                peak = peak.max(level);
            }
            *slot = peak;
        }
        bins
    }

    fn fft(&mut self) {
        let n = Self::WINDOW_SIZE;
        let mut j = 0usize;
        for i in 1..n {
            let mut bit = n >> 1;
            while (j & bit) != 0 {
                j ^= bit;
                bit >>= 1;
            }
            j ^= bit;
            if i < j {
                self.real.swap(i, j);
                self.imaginary.swap(i, j);
            }
        }
        let mut length = 2;
        while length <= n {
            let half = length / 2;
            let step = n / length;
            let mut start = 0;
            while start < n {
                for k in 0..half {
                    let wr = self.cosines[k * step];
                    let wi = self.sines[k * step];
                    let even = start + k;
                    let odd = even + half;
                    let tr = self.real[odd] * wr - self.imaginary[odd] * wi;
                    let ti = self.real[odd] * wi + self.imaginary[odd] * wr;
                    self.real[odd] = self.real[even] - tr;
                    self.imaginary[odd] = self.imaginary[even] - ti;
                    self.real[even] += tr;
                    self.imaginary[even] += ti;
                }
                start += length;
            }
            length <<= 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: f64 = 48_000.0;

    fn bins_for_sine(frequency: f64, amplitude: f64) -> Vec<f32> {
        let mut analyzer = SpectrumAnalyzer::new(RATE);
        let samples: Vec<f32> = (0..SpectrumAnalyzer::WINDOW_SIZE)
            .map(|n| (amplitude * (2.0 * PI * frequency * n as f64 / RATE).sin()) as f32)
            .collect();
        analyzer.analyze(&samples)
    }

    fn loudest(bins: &[f32]) -> (f32, usize) {
        let peak = bins.iter().copied().fold(f32::NEG_INFINITY, f32::max);
        let index = bins.iter().position(|&value| value == peak).unwrap_or(0);
        (peak, index)
    }

    fn expected_bin(frequency: f64) -> i64 {
        (SpectrumAnalyzer::BIN_COUNT as f64 * (frequency / 20.0).ln() / 1_000f64.ln()).floor() as i64
    }

    #[test]
    fn silence_reads_the_floor() {
        let mut analyzer = SpectrumAnalyzer::new(RATE);
        let silence = vec![0.0f32; SpectrumAnalyzer::WINDOW_SIZE];

        let bins = analyzer.analyze(&silence);

        assert_eq!(bins.len(), SpectrumAnalyzer::BIN_COUNT);
        assert!(bins.iter().all(|&value| value == SpectrumAnalyzer::FLOOR_DECIBELS));
    }

    #[test]
    fn a_sine_reads_its_own_level_at_its_own_frequency() {
        let frequency = 43.0 * RATE / SpectrumAnalyzer::WINDOW_SIZE as f64;

        let result = bins_for_sine(frequency, 0.5);

        let (peak, index) = loudest(&result);
        assert!((f64::from(peak) - -6.02).abs() <= 0.3, "{peak}");
        assert!((index as i64 - expected_bin(frequency)).abs() <= 1, "{index}");
    }

    #[test]
    fn the_loudest_bin_follows_the_frequency() {
        let mut previous: i64 = -1;
        for frequency in [100.0, 440.0, 2_000.0, 9_000.0] {
            let result = bins_for_sine(frequency, 0.5);
            let (_, index) = loudest(&result);
            let index = index as i64;
            assert!(index > previous, "{frequency} Hz");
            assert!((index - expected_bin(frequency)).abs() <= 2, "{frequency} Hz");
            previous = index;
        }
    }

    #[test]
    fn a_quieter_sine_reads_quieter() {
        let loud = loudest(&bins_for_sine(1_007.8, 0.5)).0;
        let quiet = loudest(&bins_for_sine(1_007.8, 0.05)).0;

        assert!((f64::from(loud - quiet) - 20.0).abs() <= 0.5, "{}", loud - quiet);
    }
}
