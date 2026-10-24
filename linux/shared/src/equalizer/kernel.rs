//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Equalizer/EqualizerKernel.swift`.
//!
//! The equalizer's signal path: a cascade of up to ten biquads, a preamp, a peak
//! guard and a dry/wet crossfade, running on 32-bit float samples with the filter
//! arithmetic in double precision. The arithmetic,
//! the ramping and the guard follow the Swift file line for line, and the impulse
//! response tests carry the same golden vectors.
//!
//! Everything a call touches is allocated in `new`, so `process` never allocates.
//! Edits are never abrupt: coefficients and preamp glide over `RAMP_FRAMES`
//! samples, and the stage crossfades in and out of the dry signal over
//! `CROSSFADE_FRAMES`, so enabling the equalizer while a song plays does not click.
//!
//! Samples live in one `&mut [f32]` buffer. Each channel is described by a `Plane`
//! (its first sample and the distance between frames), which expresses planar
//! audio (stride 1, one region per channel) and interleaved audio (stride equal to
//! the channel count, the channels at consecutive offsets) with the same call.

use super::biquad::BiquadMath;
use super::profile::EqualizerBand;

/// Where one channel's samples sit in the buffer: the index of its first frame
/// and the distance between consecutive frames.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Plane {
    pub offset: usize,
    pub stride: usize,
}

pub struct EqualizerKernel {
    channel_count: usize,
    sample_rate: f64,
    block_peak: f32,
    guard_reduced: bool,
    analysis_write_index: usize,
    start_coefficients: Vec<f64>,
    target_coefficients: Vec<f64>,
    live_coefficients: Vec<f64>,
    delay: Vec<f64>,
    analysis: Vec<f32>,
    live_sections: usize,
    target_sections: usize,
    start_gain: f64,
    target_gain: f64,
    live_gain: f64,
    wet: f32,
    target_wet: f32,
    ramp_position: usize,
    ramp_total: usize,
    has_configuration: bool,
    peak_guard_enabled: bool,
    guard_gain: f32,
    guard_release_step: f32,
}

impl EqualizerKernel {
    pub const MAX_SECTIONS: usize = EqualizerBand::MAXIMUM_PER_PROFILE;
    pub const RAMP_FRAMES: usize = 1_024;
    pub const CROSSFADE_FRAMES: usize = 1_024;
    pub const GUARD_CEILING: f32 = 1.0;
    pub const GUARD_RELEASE_SECONDS: f32 = 0.05;
    pub const ANALYSIS_CAPACITY: usize = 4_096;

    const SECTION_SLOTS: usize = Self::MAX_SECTIONS * 5;

    /// A stage for `channel_count` channels at `sample_rate`, passing audio through
    /// until it is configured.
    pub fn new(channel_count: usize, sample_rate: f64) -> Self {
        let channel_count = channel_count.max(1);
        let mut start_coefficients = vec![0.0f64; Self::SECTION_SLOTS];
        let mut target_coefficients = vec![0.0f64; Self::SECTION_SLOTS];
        let mut live_coefficients = vec![0.0f64; Self::SECTION_SLOTS];
        Self::fill_identity(&mut start_coefficients);
        Self::fill_identity(&mut target_coefficients);
        Self::fill_identity(&mut live_coefficients);
        Self {
            channel_count,
            sample_rate,
            block_peak: 0.0,
            guard_reduced: false,
            analysis_write_index: 0,
            start_coefficients,
            target_coefficients,
            live_coefficients,
            delay: vec![0.0f64; channel_count * Self::MAX_SECTIONS * 2],
            analysis: vec![0.0f32; Self::ANALYSIS_CAPACITY],
            live_sections: 0,
            target_sections: 0,
            start_gain: 1.0,
            target_gain: 1.0,
            live_gain: 1.0,
            wet: 0.0,
            target_wet: 0.0,
            ramp_position: 0,
            ramp_total: 0,
            has_configuration: false,
            peak_guard_enabled: true,
            guard_gain: 1.0,
            guard_release_step: 1.0 / (Self::GUARD_RELEASE_SECONDS * sample_rate as f32).max(1.0),
        }
    }

    pub fn channel_count(&self) -> usize {
        self.channel_count
    }

    pub fn sample_rate(&self) -> f64 {
        self.sample_rate
    }

    /// The largest absolute sample the last `process` call produced.
    pub fn block_peak(&self) -> f32 {
        self.block_peak
    }

    /// Whether the peak guard turned the signal down during the last `process` call.
    pub fn guard_reduced(&self) -> bool {
        self.guard_reduced
    }

    pub fn analysis_write_index(&self) -> usize {
        self.analysis_write_index
    }

    /// True when the stage is fully crossfaded out, not asked to come back and no
    /// longer holding the guard down: samples pass through untouched.
    pub fn is_bypassed(&self) -> bool {
        self.wet == 0.0 && self.target_wet == 0.0 && self.guard_gain >= 1.0
    }

    /// Points the stage at a new curve. Called with `is_engaged == false` it
    /// crossfades out and then passes audio through bit for bit. A kernel that
    /// has not been configured yet fades the curve in; see `configure_starting`.
    pub fn configure(
        &mut self,
        bands: &[EqualizerBand],
        preamp_decibels: f64,
        is_engaged: bool,
        peak_guard: bool,
    ) {
        self.configure_starting(bands, preamp_decibels, is_engaged, peak_guard, false);
    }

    /// `configure`, and for the first call it decides how the stage begins. A
    /// kernel born with the beginning of a song passes `starts_engaged` so the
    /// curve is in force on the first sample; one that appears under a song
    /// already playing leaves it off and crossfades in, so turning the equalizer
    /// on mid-song does not click.
    pub fn configure_starting(
        &mut self,
        bands: &[EqualizerBand],
        preamp_decibels: f64,
        is_engaged: bool,
        peak_guard: bool,
        starts_engaged: bool,
    ) {
        let first = !self.has_configuration;
        self.has_configuration = true;
        self.peak_guard_enabled = peak_guard;

        self.start_coefficients
            .copy_from_slice(&self.live_coefficients);
        self.start_gain = self.live_gain;

        let mut count = 0;
        for band in bands
            .iter()
            .filter(|band| band.is_enabled)
            .take(Self::MAX_SECTIONS)
        {
            let c = BiquadMath::coefficients_for(band, self.sample_rate);
            if ![c.b0, c.b1, c.b2, c.a1, c.a2].iter().all(|value| value.is_finite()) {
                continue;
            }
            let base = count * 5;
            self.target_coefficients[base] = c.b0;
            self.target_coefficients[base + 1] = c.b1;
            self.target_coefficients[base + 2] = c.b2;
            self.target_coefficients[base + 3] = c.a1;
            self.target_coefficients[base + 4] = c.a2;
            count += 1;
        }
        if count < Self::MAX_SECTIONS {
            Self::fill_identity(&mut self.target_coefficients[count * 5..]);
        }
        self.target_sections = count;
        self.target_gain = 10f64.powf(preamp_decibels / 20.0);
        self.target_wet = if is_engaged { 1.0 } else { 0.0 };

        if first {
            self.start_coefficients
                .copy_from_slice(&self.target_coefficients);
            self.live_coefficients
                .copy_from_slice(&self.target_coefficients);
            self.start_gain = self.target_gain;
            self.live_gain = self.target_gain;
            self.live_sections = self.target_sections;
            self.ramp_total = 0;
            self.ramp_position = 0;
            self.wet = if starts_engaged && is_engaged { 1.0 } else { 0.0 };
        } else {
            self.ramp_total = Self::RAMP_FRAMES;
            self.ramp_position = 0;
        }
    }

    /// Forgets the filters' memory. Called on a seek or an item change, where the
    /// signal is discontinuous and old state would ring into the new audio.
    pub fn reset(&mut self) {
        self.delay.iter_mut().for_each(|value| *value = 0.0);
        self.guard_gain = 1.0;
    }

    /// Runs `frames` frames in place over `buffer`, one `Plane` per channel.
    ///
    /// Panics when `planes` does not hold one entry per channel or when a plane
    /// reaches past the end of `buffer`.
    pub fn process(&mut self, buffer: &mut [f32], planes: &[Plane], frames: usize) {
        if frames == 0 {
            return;
        }
        assert_eq!(planes.len(), self.channel_count, "one plane per channel");
        for plane in planes {
            assert!(
                Self::index(*plane, frames - 1) < buffer.len(),
                "plane runs past the end of the buffer"
            );
        }

        if self.is_bypassed() {
            let mut peak = 0.0f32;
            for plane in planes {
                for frame in 0..frames {
                    peak = peak.max(buffer[Self::index(*plane, frame)].abs());
                }
            }
            self.block_peak = peak;
            self.guard_reduced = false;
            self.feed_analysis(buffer, planes, frames);
            return;
        }

        let sections = self.live_sections.max(self.target_sections);
        let wet_step = 1.0 / Self::CROSSFADE_FRAMES as f32;
        let use_guard = self.peak_guard_enabled;
        let ceiling = Self::GUARD_CEILING;
        let release_step = self.guard_release_step;
        let mut peak = 0.0f32;
        let mut reduced = false;

        for frame in 0..frames {
            if self.ramp_position < self.ramp_total {
                self.ramp_position += 1;
                let ramp_fraction = self.ramp_position as f64 / self.ramp_total as f64;
                for slot in 0..(sections * 5) {
                    let from = self.start_coefficients[slot];
                    self.live_coefficients[slot] =
                        from + (self.target_coefficients[slot] - from) * ramp_fraction;
                }
                self.live_gain = self.start_gain + (self.target_gain - self.start_gain) * ramp_fraction;
            } else if self.ramp_total > 0 {
                for slot in 0..(sections * 5) {
                    self.live_coefficients[slot] = self.target_coefficients[slot];
                }
                self.live_gain = self.target_gain;
                self.live_sections = self.target_sections;
                self.ramp_total = 0;
                self.ramp_position = 0;
            }

            let mix = self.wet;
            if self.wet < self.target_wet {
                self.wet = (self.wet + wet_step).min(self.target_wet);
            } else if self.wet > self.target_wet {
                self.wet = (self.wet - wet_step).max(self.target_wet);
            }

            let mut frame_max = 0.0f32;
            for channel in 0..self.channel_count {
                let index = Self::index(planes[channel], frame);
                let dry = buffer[index];
                let mut value = f64::from(dry) * self.live_gain;
                let state = channel * Self::MAX_SECTIONS * 2;
                for section in 0..sections {
                    let c = section * 5;
                    let z = state + section * 2;
                    let out = self.live_coefficients[c] * value + self.delay[z];
                    self.delay[z] = self.live_coefficients[c + 1] * value
                        - self.live_coefficients[c + 3] * out
                        + self.delay[z + 1];
                    self.delay[z + 1] =
                        self.live_coefficients[c + 2] * value - self.live_coefficients[c + 4] * out;
                    value = out;
                }
                let mixed = dry + (value as f32 - dry) * mix;
                buffer[index] = mixed;
                frame_max = frame_max.max(mixed.abs());
            }

            if use_guard {
                let mut wanted = 1.0f32;
                if frame_max > ceiling {
                    wanted = ceiling / frame_max;
                }
                self.guard_gain = wanted.min(self.guard_gain + release_step);
                if self.guard_gain < 1.0 {
                    reduced = reduced || self.guard_gain < 0.999;
                    frame_max = 0.0;
                    for plane in planes {
                        let index = Self::index(*plane, frame);
                        buffer[index] *= self.guard_gain;
                        frame_max = frame_max.max(buffer[index].abs());
                    }
                }
            }
            peak = peak.max(frame_max);
        }

        if self.ramp_total > 0 && self.ramp_position >= self.ramp_total {
            for slot in 0..(sections * 5) {
                self.live_coefficients[slot] = self.target_coefficients[slot];
            }
            self.live_gain = self.target_gain;
            self.live_sections = self.target_sections;
            self.ramp_total = 0;
            self.ramp_position = 0;
            if self.target_sections < sections {
                self.clear_delay(self.target_sections);
            }
        }

        self.block_peak = peak;
        self.guard_reduced = reduced;
        self.feed_analysis(buffer, planes, frames);
    }

    /// Copies the most recent `count` mono analysis samples, oldest first, into the
    /// front of `output`.
    ///
    /// Panics when `output` holds fewer samples than the number copied.
    pub fn copy_analysis(&self, output: &mut [f32], count: usize) {
        let capacity = Self::ANALYSIS_CAPACITY;
        let n = count.min(capacity);
        let mut index = (self.analysis_write_index + capacity - n) % capacity;
        for slot in output[..n].iter_mut() {
            *slot = self.analysis[index];
            index = (index + 1) % capacity;
        }
    }

    fn index(plane: Plane, frame: usize) -> usize {
        plane.offset + frame * plane.stride
    }

    fn feed_analysis(&mut self, buffer: &[f32], planes: &[Plane], frames: usize) {
        let capacity = Self::ANALYSIS_CAPACITY;
        let scale = 1.0 / self.channel_count as f32;
        let mut index = self.analysis_write_index;
        for frame in 0..frames {
            let mut sum = 0.0f32;
            for plane in planes {
                sum += buffer[Self::index(*plane, frame)];
            }
            self.analysis[index] = sum * scale;
            index += 1;
            if index == capacity {
                index = 0;
            }
        }
        self.analysis_write_index = index;
    }

    fn clear_delay(&mut self, from: usize) {
        for channel in 0..self.channel_count {
            let state = channel * Self::MAX_SECTIONS * 2;
            for section in from..Self::MAX_SECTIONS {
                self.delay[state + section * 2] = 0.0;
                self.delay[state + section * 2 + 1] = 0.0;
            }
        }
    }

    fn fill_identity(slots: &mut [f64]) {
        for section in slots.chunks_exact_mut(5) {
            section.copy_from_slice(&[1.0, 0.0, 0.0, 0.0, 0.0]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::equalizer::biquad::{Coefficients, FilterType};
    use crate::equalizer::presets::EqualizerPresets;
    use crate::equalizer::test_support::Lcg;
    use std::f64::consts::PI;

    const RATE: f64 = 48_000.0;
    const CHUNK: usize = 512;

    fn run(kernel: &mut EqualizerKernel, planar: &[Vec<f32>]) -> Vec<Vec<f32>> {
        let channels = planar.len();
        let frames = planar[0].len();
        let mut buffer: Vec<f32> = planar.concat();
        let mut start = 0;
        while start < frames {
            let count = CHUNK.min(frames - start);
            let planes: Vec<Plane> = (0..channels)
                .map(|channel| Plane {
                    offset: channel * frames + start,
                    stride: 1,
                })
                .collect();
            kernel.process(&mut buffer, &planes, count);
            start += count;
        }
        buffer.chunks(frames).map(|channel| channel.to_vec()).collect()
    }

    fn settle(kernel: &mut EqualizerKernel, channels: usize) {
        let silence = vec![vec![0.0f32; 3_000]; channels];
        run(kernel, &silence);
    }

    fn impulse(length: usize) -> Vec<Vec<f32>> {
        let mut samples = vec![0.0f32; length];
        samples[0] = 1.0;
        vec![samples]
    }

    fn sine(frequency: f64, amplitude: f64, length: usize) -> Vec<f32> {
        (0..length)
            .map(|n| (amplitude * (2.0 * PI * frequency * n as f64 / RATE).sin()) as f32)
            .collect()
    }

    #[test]
    fn the_impulse_response_matches_the_golden_vector() {
        let mut kernel = EqualizerKernel::new(1, RATE);
        kernel.configure(
            &[EqualizerBand::new(FilterType::Bell, 1_000.0, 6.0, Some(1.41), true)],
            -2.0,
            true,
            false,
        );
        settle(&mut kernel, 1);

        let response = run(&mut kernel, &impulse(64)).remove(0);

        let golden: [f32; 8] = [
            0.819411461,
            0.048159196,
            0.043889747,
            0.039164084,
            0.034089448,
            0.028772056,
            0.023315410,
            0.017818747,
        ];
        for (index, expected) in golden.iter().enumerate() {
            assert!(
                (response[index] - expected).abs() <= 1e-6,
                "sample {index}: {} != {expected}",
                response[index]
            );
        }
    }

    #[test]
    fn the_impulse_response_matches_a_double_precision_reference() {
        let bands = [
            EqualizerBand::new(FilterType::Bell, 1_000.0, 6.0, Some(1.41), true),
            EqualizerBand::new(FilterType::LowShelf, 120.0, -3.0, Some(0.71), true),
            EqualizerBand::new(FilterType::HighShelf, 9_000.0, 4.0, Some(0.71), true),
        ];
        let mut kernel = EqualizerKernel::new(1, RATE);
        kernel.configure(&bands, -3.0, true, false);
        settle(&mut kernel, 1);

        let response = run(&mut kernel, &impulse(2_048)).remove(0);

        let gain = 10f64.powf(-3.0 / 20.0);
        let coefficients: Vec<Coefficients> = bands
            .iter()
            .map(|band| BiquadMath::coefficients_for(band, RATE))
            .collect();
        let mut z = vec![(0.0f64, 0.0f64); bands.len()];
        for (n, sample) in response.iter().enumerate() {
            let mut value = (if n == 0 { 1.0 } else { 0.0 }) * gain;
            for (section, c) in coefficients.iter().enumerate() {
                let out = c.b0 * value + z[section].0;
                z[section].0 = c.b1 * value - c.a1 * out + z[section].1;
                z[section].1 = c.b2 * value - c.a2 * out;
                value = out;
            }
            assert!(
                (f64::from(*sample) - value).abs() <= 2e-5,
                "sample {n}: {sample} != {value}"
            );
        }
    }

    #[test]
    fn the_kernels_frequency_response_is_the_curve_that_is_drawn() {
        let bands = EqualizerPresets::profile_for_key("rock").unwrap().resolved_bands();
        let mut kernel = EqualizerKernel::new(1, RATE);
        kernel.configure(&bands, 0.0, true, false);
        settle(&mut kernel, 1);

        let response = run(&mut kernel, &impulse(16_384)).remove(0);

        for frequency in [60.0, 250.0, 1_000.0, 4_000.0, 12_000.0] {
            let mut re = 0.0f64;
            let mut im = 0.0f64;
            for (n, sample) in response.iter().enumerate() {
                let phase = 2.0 * PI * frequency * n as f64 / RATE;
                re += f64::from(*sample) * phase.cos();
                im -= f64::from(*sample) * phase.sin();
            }
            let heard = 20.0 * (re * re + im * im).sqrt().log10();
            let expected = BiquadMath::response_decibels(&bands, frequency);
            assert!(
                (heard - expected).abs() <= 0.05,
                "{frequency} Hz: {heard} != {expected}"
            );
        }
    }

    #[test]
    fn a_bypassed_stage_leaves_every_sample_bit_exact() {
        let mut kernel = EqualizerKernel::new(2, RATE);
        kernel.configure(
            &EqualizerPresets::profile_for_key("rock").unwrap().resolved_bands(),
            -4.0,
            false,
            true,
        );
        let mut generator = Lcg::new(1_234_567);
        let input: Vec<Vec<f32>> = (0..2)
            .map(|_| {
                (0..4_096)
                    .map(|_| (generator.range(-1.0, 1.0)) as f32)
                    .collect()
            })
            .collect();

        let output = run(&mut kernel, &input);

        assert_eq!(output, input);
        assert!(kernel.is_bypassed());
    }

    #[test]
    fn engaging_starts_from_the_dry_signal_so_nothing_clicks() {
        let mut kernel = EqualizerKernel::new(1, RATE);
        kernel.configure(
            &[EqualizerBand::new(FilterType::Bell, 500.0, 9.0, Some(1.0), true)],
            -9.0,
            true,
            false,
        );
        let tone = sine(440.0, 0.5, 4_096);

        let output = run(&mut kernel, &[tone.clone()]).remove(0);

        assert_eq!(output[0], tone[0]);
        let mut largest_step = 0.0f32;
        for n in 1..output.len() {
            largest_step = largest_step.max((output[n] - output[n - 1]).abs());
        }
        assert!(largest_step < 0.1, "{largest_step}");
    }

    #[test]
    fn disengaging_crossfades_out_and_then_passes_audio_through_untouched() {
        let mut kernel = EqualizerKernel::new(1, RATE);
        kernel.configure(
            &[EqualizerBand::new(FilterType::Bell, 500.0, 9.0, Some(1.0), true)],
            -9.0,
            true,
            false,
        );
        settle(&mut kernel, 1);

        kernel.configure(&[], 0.0, false, false);
        let tone = sine(330.0, 0.4, 8_192);
        let output = run(&mut kernel, &[tone.clone()]).remove(0);

        assert!(kernel.is_bypassed());
        assert_eq!(output[4_096..], tone[4_096..]);
    }

    #[test]
    fn the_peak_guard_holds_the_ceiling() {
        let mut kernel = EqualizerKernel::new(2, RATE);
        kernel.configure(&[], 6.0, true, true);
        let tone = sine(220.0, 0.95, 8_192);
        settle(&mut kernel, 2);

        let output = run(&mut kernel, &[tone.clone(), tone]);

        let peak = output
            .iter()
            .flatten()
            .map(|sample| sample.abs())
            .fold(0.0f32, f32::max);
        assert!(peak <= EqualizerKernel::GUARD_CEILING + 1e-5, "{peak}");
        assert!(kernel.guard_reduced());
    }

    #[test]
    fn without_the_guard_a_boost_can_exceed_full_scale() {
        let mut kernel = EqualizerKernel::new(1, RATE);
        kernel.configure(&[], 6.0, true, false);
        settle(&mut kernel, 1);
        let tone = sine(220.0, 0.9, 4_096);

        let output = run(&mut kernel, &[tone]).remove(0);

        let peak = output.iter().map(|sample| sample.abs()).fold(0.0f32, f32::max);
        assert!(peak > 1.0, "{peak}");
    }

    #[test]
    fn changing_the_curve_while_playing_never_jumps() {
        let mut kernel = EqualizerKernel::new(1, RATE);
        kernel.configure(
            &[EqualizerBand::new(FilterType::Bell, 200.0, 8.0, Some(1.0), true)],
            0.0,
            true,
            false,
        );
        settle(&mut kernel, 1);
        let tone = sine(100.0, 0.4, 6_144);

        let first = run(&mut kernel, &[tone[0..3_072].to_vec()]).remove(0);
        kernel.configure(
            &[EqualizerBand::new(FilterType::Bell, 300.0, -8.0, Some(2.0), true)],
            0.0,
            true,
            false,
        );
        let second = run(&mut kernel, &[tone[3_072..].to_vec()]).remove(0);

        let stream: Vec<f32> = first.into_iter().chain(second).collect();
        let mut largest_step = 0.0f32;
        for n in 1..stream.len() {
            largest_step = largest_step.max((stream[n] - stream[n - 1]).abs());
        }
        assert!(largest_step < 0.03, "{largest_step}");
    }

    #[test]
    fn channels_are_processed_independently() {
        let mut kernel = EqualizerKernel::new(2, RATE);
        kernel.configure(
            &[EqualizerBand::new(FilterType::Bell, 1_000.0, 6.0, Some(1.41), true)],
            -6.0,
            true,
            false,
        );
        settle(&mut kernel, 2);
        let mut left = vec![0.0f32; 64];
        left[0] = 1.0;
        let right = vec![0.0f32; 64];

        let output = run(&mut kernel, &[left, right]);

        assert!(output[0][0].abs() > 0.1);
        assert!(output[1].iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn interleaved_and_planar_audio_come_out_the_same() {
        let bands = EqualizerPresets::profile_for_key("electronic")
            .unwrap()
            .resolved_bands();
        let mut planar_kernel = EqualizerKernel::new(2, RATE);
        let mut interleaved_kernel = EqualizerKernel::new(2, RATE);
        for kernel in [&mut planar_kernel, &mut interleaved_kernel] {
            kernel.configure(&bands, -5.0, true, true);
        }
        let left = sine(180.0, 0.3, 3_000);
        let right = sine(2_400.0, 0.3, 3_000);
        let planar = run(&mut planar_kernel, &[left.clone(), right.clone()]);

        let mut interleaved = vec![0.0f32; 6_000];
        for n in 0..3_000 {
            interleaved[n * 2] = left[n];
            interleaved[n * 2 + 1] = right[n];
        }
        interleaved_kernel.process(
            &mut interleaved,
            &[
                Plane {
                    offset: 0,
                    stride: 2,
                },
                Plane {
                    offset: 1,
                    stride: 2,
                },
            ],
            3_000,
        );

        for n in 0..3_000 {
            assert!((interleaved[n * 2] - planar[0][n]).abs() <= 1e-6, "left {n}");
            assert!((interleaved[n * 2 + 1] - planar[1][n]).abs() <= 1e-6, "right {n}");
        }
    }

    #[test]
    fn a_kernel_born_with_a_song_has_the_curve_in_force_from_its_first_sample() {
        let mut kernel = EqualizerKernel::new(1, RATE);
        kernel.configure_starting(&[], -6.0, true, true, true);

        let output = run(&mut kernel, &[vec![0.5f32; 64]]).remove(0);

        let expected = (0.5 * 10f64.powf(-6.0 / 20.0)) as f32;
        assert!((output[0] - expected).abs() <= 1e-6, "{}", output[0]);
        assert!((output[63] - expected).abs() <= 1e-6, "{}", output[63]);
    }

    #[test]
    fn a_kernel_that_appears_under_a_playing_song_still_fades_in() {
        let mut kernel = EqualizerKernel::new(1, RATE);
        kernel.configure(&[], -6.0, true, true);

        let output = run(&mut kernel, &[vec![0.5f32; 64]]).remove(0);

        assert!((output[0] - 0.5).abs() <= 1e-3, "{}", output[0]);
        assert!(output[63] < 0.5, "{}", output[63]);
    }

    #[test]
    fn the_guard_leaves_a_hot_master_alone_when_nothing_is_boosted() {
        let mut kernel = EqualizerKernel::new(1, RATE);
        kernel.configure_starting(
            &[EqualizerBand::new(FilterType::Bell, 60.0, -2.0, Some(1.41), true)],
            0.0,
            true,
            true,
            true,
        );
        let tone = sine(3_000.0, 0.99, 8_192);

        let output = run(&mut kernel, &[tone]).remove(0);

        assert!(!kernel.guard_reduced());
        let peak = output.iter().map(|sample| sample.abs()).fold(0.0f32, f32::max);
        assert!((peak - 0.99).abs() <= 0.01, "{peak}");
    }

    #[test]
    fn disengaging_while_the_guard_is_acting_leaves_no_step_when_it_hands_over() {
        let mut kernel = EqualizerKernel::new(1, RATE);
        kernel.configure_starting(&[], 6.0, true, true, true);
        run(&mut kernel, &[vec![0.8f32; 4_096]]);
        kernel.configure(&[], 6.0, false, true);

        let mut gains = Vec::new();
        for _ in 0..(12_000 / 256 + 1) {
            let chunk = run(&mut kernel, &[vec![0.8f32; 256]]).remove(0);
            gains.extend(chunk.iter().map(|sample| f64::from(*sample) / 0.8));
        }

        let largest_step = gains
            .windows(2)
            .map(|pair| (pair[1] - pair[0]).abs())
            .fold(0.0f64, f64::max);
        assert!(largest_step < 0.002, "{largest_step}");
        assert!((gains[gains.len() - 1] - 1.0).abs() <= 1e-6);
        assert!(kernel.is_bypassed());
    }

    #[test]
    fn a_band_that_is_not_a_number_cannot_poison_the_audio() {
        let mut kernel = EqualizerKernel::new(1, RATE);
        kernel.configure_starting(
            &[
                EqualizerBand::new(FilterType::Bell, f64::NAN, 3.0, Some(1.0), true),
                EqualizerBand::new(FilterType::Bell, 1_000.0, f64::NAN, Some(1.0), true),
            ],
            0.0,
            true,
            true,
            true,
        );

        let output = run(&mut kernel, &[sine(440.0, 0.5, 2_048)]).remove(0);

        assert!(output.iter().all(|sample| sample.is_finite()));
    }

    #[test]
    fn reset_clears_the_filters_memory() {
        let mut kernel = EqualizerKernel::new(1, RATE);
        kernel.configure(
            &[EqualizerBand::new(FilterType::Bell, 200.0, 10.0, Some(4.0), true)],
            0.0,
            true,
            false,
        );
        settle(&mut kernel, 1);
        run(&mut kernel, &impulse(32));

        kernel.reset();
        let silence = run(&mut kernel, &[vec![0.0f32; 256]]).remove(0);

        assert!(silence.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn the_analysis_ring_holds_the_most_recent_samples() {
        let mut kernel = EqualizerKernel::new(1, RATE);
        kernel.configure(&[], 0.0, false, false);
        let ramp: Vec<f32> = (0..5_000).map(|n| n as f32 / 5_000.0).collect();
        run(&mut kernel, &[ramp.clone()]);

        let mut window = vec![0.0f32; 100];
        kernel.copy_analysis(&mut window, 100);

        assert_eq!(window, ramp[4_900..5_000].to_vec());
    }

    #[test]
    fn the_analysis_ring_wraps_after_its_capacity() {
        let mut kernel = EqualizerKernel::new(1, RATE);
        kernel.configure(&[], 0.0, false, false);
        let capacity = EqualizerKernel::ANALYSIS_CAPACITY;
        let ramp: Vec<f32> = (0..capacity + 300).map(|n| n as f32).collect();
        run(&mut kernel, &[ramp.clone()]);

        let mut window = vec![0.0f32; 4];
        kernel.copy_analysis(&mut window, 4);

        assert_eq!(window, ramp[ramp.len() - 4..].to_vec());
        assert_eq!(kernel.analysis_write_index(), 300);
    }
}
