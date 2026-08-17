use std::path::Path;
use std::process::{Command, Stdio};

/// Everything downstream of the decoder works at this rate. Onsets are a
/// rhythmic feature, not a timbral one, so 11 kHz carries every cue that
/// matters at a quarter of the samples.
const SAMPLE_RATE: usize = 11025;
const FRAME: usize = 1024;
const HOP: usize = 256;

/// How much of each recording is examined. Long enough that a chorus lands
/// inside the window even after a lengthy video intro, short enough that
/// decoding stays under a second.
const ANALYSIS_SECONDS: usize = 180;

/// A music video can open with dialogue, a title card or a whole scene before
/// the song starts, and can equally start mid-song. Both directions are
/// searched.
const MAX_LAG_SECONDS: f64 = 60.0;

/// Below this much overlapping audio a correlation peak means nothing, so lags
/// that would leave less than this are not scored at all.
const MIN_OVERLAP_SECONDS: f64 = 30.0;

/// How far the winning lag must stand out from the field, in standard
/// deviations. A genuine alignment produces a single sharp spike; two
/// different recordings produce noise with no spike at all.
const MIN_PEAK_Z: f64 = 4.5;

/// A floor on the correlation itself, so a flat, low-contrast field can't
/// produce a high z-score out of nothing.
const MIN_PEAK_CORRELATION: f64 = 0.12;

fn frames_per_second() -> f64 {
    SAMPLE_RATE as f64 / HOP as f64
}

pub struct Alignment {
    /// Seconds to add to a position in the local audio to reach the same
    /// musical moment in the video.
    pub offset: f64,
    pub confidence: f64,
}

/// Estimates how far the video's audio runs ahead of (or behind) the library
/// file, by correlating the two recordings' onset envelopes. Returns `None`
/// unless the match is unambiguous — a wrong offset is worse than the zero the
/// caller falls back to.
pub fn estimate(local: &Path, video_audio: &Path) -> Option<Alignment> {
    let local_samples = decode_mono(local)?;
    let video_samples = decode_mono(video_audio)?;
    let local_envelope = onset_envelope(&local_samples);
    let video_envelope = onset_envelope(&video_samples);
    correlate(&local_envelope, &video_envelope)
}

/// Decodes any container ffmpeg understands down to mono f32 at the analysis
/// rate, capped at the analysis window.
fn decode_mono(path: &Path) -> Option<Vec<f32>> {
    let ffmpeg = crate::downloads::resolve_tool("ffmpeg")?;
    let output = Command::new(ffmpeg)
        .args(["-v", "error", "-nostdin"])
        .arg("-i")
        .arg(path)
        .args(["-t", &ANALYSIS_SECONDS.to_string()])
        .args(["-ac", "1", "-ar", &SAMPLE_RATE.to_string()])
        .args(["-f", "f32le", "-"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() || output.stdout.len() < FRAME * 4 {
        return None;
    }
    Some(
        output
            .stdout
            .chunks_exact(4)
            .map(|bytes| f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
            .collect(),
    )
}

/// Spectral flux: per frame, the total rise in magnitude across the spectrum.
/// It peaks on note and drum onsets and is blind to level, EQ and mastering,
/// which is exactly the difference between an album master and a video's
/// soundtrack.
pub fn onset_envelope(samples: &[f32]) -> Vec<f64> {
    if samples.len() < FRAME {
        return Vec::new();
    }
    let window = hann(FRAME);
    let bins = FRAME / 2;
    let mut previous = vec![0.0f64; bins];
    let mut envelope = Vec::with_capacity((samples.len() - FRAME) / HOP + 1);
    let mut real = vec![0.0f64; FRAME];
    let mut imag = vec![0.0f64; FRAME];

    let mut start = 0;
    while start + FRAME <= samples.len() {
        for index in 0..FRAME {
            real[index] = samples[start + index] as f64 * window[index];
            imag[index] = 0.0;
        }
        fft(&mut real, &mut imag);
        let mut flux = 0.0;
        for bin in 0..bins {
            let magnitude = (real[bin] * real[bin] + imag[bin] * imag[bin]).sqrt();
            let rise = magnitude - previous[bin];
            if rise > 0.0 {
                flux += rise;
            }
            previous[bin] = magnitude;
        }
        envelope.push(flux);
        start += HOP;
    }
    if !envelope.is_empty() {
        envelope[0] = 0.0;
    }
    sharpen(&envelope)
}

/// Standard onset post-processing: subtract a local average and keep only what
/// rises above it. This strips the slow loudness contour — the part two
/// masters of the same song disagree about most — and leaves the attacks,
/// which they agree on.
fn sharpen(envelope: &[f64]) -> Vec<f64> {
    let window = (0.5 * frames_per_second()) as usize;
    if envelope.len() <= window || window == 0 {
        return envelope.to_vec();
    }
    envelope
        .iter()
        .enumerate()
        .map(|(index, value)| {
            let start = index.saturating_sub(window);
            let end = (index + window + 1).min(envelope.len());
            let local = envelope[start..end].iter().sum::<f64>() / (end - start) as f64;
            (value - local).max(0.0)
        })
        .collect()
}

/// Finds the lag at which the two envelopes agree best, and decides whether
/// that agreement is real. `local` and `video` are onset envelopes at the
/// analysis frame rate.
pub fn correlate(local: &[f64], video: &[f64]) -> Option<Alignment> {
    let fps = frames_per_second();
    let max_lag = (MAX_LAG_SECONDS * fps) as isize;
    let min_overlap = (MIN_OVERLAP_SECONDS * fps) as usize;
    if local.len() < min_overlap || video.len() < min_overlap {
        return None;
    }
    let local = standardize(local);
    let video = standardize(video);

    let mut scores: Vec<(isize, f64)> = Vec::new();
    for lag in -max_lag..=max_lag {
        if let Some(score) = correlation_at(&local, &video, lag, min_overlap) {
            scores.push((lag, score));
        }
    }
    if scores.len() < 8 {
        return None;
    }

    let (best_lag, best_score) = scores
        .iter()
        .copied()
        .max_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))?;
    let mean = scores.iter().map(|(_, score)| score).sum::<f64>() / scores.len() as f64;
    let variance = scores
        .iter()
        .map(|(_, score)| (score - mean) * (score - mean))
        .sum::<f64>()
        / scores.len() as f64;
    let deviation = variance.sqrt();
    if deviation <= f64::EPSILON {
        return None;
    }
    let z = (best_score - mean) / deviation;
    if z < MIN_PEAK_Z || best_score < MIN_PEAK_CORRELATION {
        return None;
    }
    Some(Alignment {
        offset: best_lag as f64 / fps,
        confidence: (z / (MIN_PEAK_Z * 2.0)).clamp(0.0, 1.0),
    })
}

/// Mean-removed, unit-variance envelope, so a plain dot product over the
/// overlap is a correlation.
fn standardize(values: &[f64]) -> Vec<f64> {
    let mean = values.iter().sum::<f64>() / values.len() as f64;
    let variance = values
        .iter()
        .map(|value| (value - mean) * (value - mean))
        .sum::<f64>()
        / values.len() as f64;
    let deviation = variance.sqrt();
    if deviation <= f64::EPSILON {
        return vec![0.0; values.len()];
    }
    values.iter().map(|value| (value - mean) / deviation).collect()
}

fn correlation_at(local: &[f64], video: &[f64], lag: isize, min_overlap: usize) -> Option<f64> {
    let (local_start, video_start) = if lag >= 0 {
        (0usize, lag as usize)
    } else {
        ((-lag) as usize, 0usize)
    };
    if local_start >= local.len() || video_start >= video.len() {
        return None;
    }
    let overlap = (local.len() - local_start).min(video.len() - video_start);
    if overlap < min_overlap {
        return None;
    }
    let sum: f64 = (0..overlap)
        .map(|index| local[local_start + index] * video[video_start + index])
        .sum();
    Some(sum / overlap as f64)
}

fn hann(size: usize) -> Vec<f64> {
    (0..size)
        .map(|index| {
            let phase = std::f64::consts::TAU * index as f64 / size as f64;
            0.5 - 0.5 * phase.cos()
        })
        .collect()
}

/// In-place iterative radix-2 FFT. `real` and `imag` must be the same
/// power-of-two length.
pub fn fft(real: &mut [f64], imag: &mut [f64]) {
    let n = real.len();
    debug_assert!(n.is_power_of_two());
    debug_assert_eq!(n, imag.len());

    let mut target = 0usize;
    for source in 1..n {
        let mut bit = n >> 1;
        while target & bit != 0 {
            target ^= bit;
            bit >>= 1;
        }
        target |= bit;
        if source < target {
            real.swap(source, target);
            imag.swap(source, target);
        }
    }

    let mut span = 2;
    while span <= n {
        let step = -std::f64::consts::TAU / span as f64;
        let half = span / 2;
        for block in (0..n).step_by(span) {
            for offset in 0..half {
                let angle = step * offset as f64;
                let (sin, cos) = angle.sin_cos();
                let index = block + offset;
                let partner = index + half;
                let real_part = real[partner] * cos - imag[partner] * sin;
                let imag_part = real[partner] * sin + imag[partner] * cos;
                real[partner] = real[index] - real_part;
                imag[partner] = imag[index] - imag_part;
                real[index] += real_part;
                imag[index] += imag_part;
            }
        }
        span <<= 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn naive_dft(input: &[f64]) -> Vec<(f64, f64)> {
        let n = input.len();
        (0..n)
            .map(|bin| {
                let mut real = 0.0;
                let mut imag = 0.0;
                for (index, value) in input.iter().enumerate() {
                    let angle = -std::f64::consts::TAU * bin as f64 * index as f64 / n as f64;
                    real += value * angle.cos();
                    imag += value * angle.sin();
                }
                (real, imag)
            })
            .collect()
    }

    #[test]
    fn fft_matches_a_naive_transform() {
        let input: Vec<f64> = (0..64)
            .map(|index| (index as f64 * 0.37).sin() + 0.3 * (index as f64 * 1.9).cos())
            .collect();
        let expected = naive_dft(&input);
        let mut real = input.clone();
        let mut imag = vec![0.0; input.len()];
        fft(&mut real, &mut imag);
        for bin in 0..input.len() {
            assert!((real[bin] - expected[bin].0).abs() < 1e-9, "bin {bin} real");
            assert!((imag[bin] - expected[bin].1).abs() < 1e-9, "bin {bin} imag");
        }
    }

    /// Renders a short passage of "music": note attacks at irregular intervals
    /// with varying pitch and loudness, so the pattern never repeats and a
    /// correlation has one true answer. `gain` and `bright` stand in for a
    /// different master of the same recording.
    fn render(seconds: f64, seed: u64, gain: f32, bright: f32) -> Vec<f32> {
        let total = (seconds * SAMPLE_RATE as f64) as usize;
        let mut samples = vec![0.0f32; total];
        let mut state = seed;
        let mut next = |modulo: u64| {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (state >> 33) % modulo
        };
        let mut at = 0.0f64;
        while at < seconds {
            let pitch = 110.0 * (1 + next(12)) as f64 / 4.0;
            let level = 0.25 + next(100) as f64 / 200.0;
            let decay = 6.0 + next(40) as f64 / 10.0;
            let start = (at * SAMPLE_RATE as f64) as usize;
            for offset in 0..(SAMPLE_RATE / 3) {
                let index = start + offset;
                if index >= total {
                    break;
                }
                let time = offset as f64 / SAMPLE_RATE as f64;
                let envelope = (-decay * time).exp() * level;
                let phase = std::f64::consts::TAU * pitch * time;
                let tone = phase.sin() + bright as f64 * (phase * 2.0).sin();
                samples[index] += (envelope * tone) as f32 * gain;
            }
            at += 0.17 + next(45) as f64 / 100.0;
        }
        samples
    }

    #[test]
    fn recovers_a_video_that_starts_late() {
        let head_start = 12.0;
        let master = render(140.0, 7, 1.0, 0.15);
        let video = render(140.0, 7, 0.6, 0.45);
        let local = onset_envelope(&master[(head_start * SAMPLE_RATE as f64) as usize..]);
        let video = onset_envelope(&video);
        let alignment = correlate(&local, &video).expect("the same passage must align");
        assert!(
            (alignment.offset - head_start).abs() < 0.2,
            "offset was {}",
            alignment.offset
        );
        assert!(alignment.confidence > 0.0);
    }

    #[test]
    fn recovers_a_video_that_starts_early() {
        let head_start = 9.0;
        let master = render(140.0, 21, 1.0, 0.2);
        let video = render(140.0, 21, 1.4, 0.05);
        let local = onset_envelope(&master);
        let video = onset_envelope(&video[(head_start * SAMPLE_RATE as f64) as usize..]);
        let alignment = correlate(&local, &video).expect("the same passage must align");
        assert!(
            (alignment.offset + head_start).abs() < 0.2,
            "offset was {}",
            alignment.offset
        );
    }

    #[test]
    fn two_unrelated_recordings_produce_no_alignment() {
        let local = onset_envelope(&render(140.0, 3, 1.0, 0.2));
        let video = onset_envelope(&render(140.0, 999_331, 1.0, 0.2));
        assert!(correlate(&local, &video).is_none());
    }

    #[test]
    fn too_little_audio_produces_no_alignment() {
        let short = onset_envelope(&render(12.0, 5, 1.0, 0.2));
        assert!(correlate(&short, &short).is_none());
    }

    #[test]
    fn silence_produces_no_alignment() {
        let silence = vec![0.0; 6000];
        assert!(correlate(&silence, &silence).is_none());
    }

    #[test]
    fn an_envelope_reacts_to_onsets_not_to_steady_tone() {
        let steady: Vec<f32> = (0..SAMPLE_RATE * 2)
            .map(|index| (index as f32 * 0.05).sin() * 0.5)
            .collect();
        let mut bursty = vec![0.0f32; SAMPLE_RATE * 2];
        for (index, sample) in bursty.iter_mut().enumerate() {
            if index % (SAMPLE_RATE / 2) < 400 {
                *sample = (index as f32 * 0.4).sin();
            }
        }
        let steady_envelope = onset_envelope(&steady);
        let bursty_envelope = onset_envelope(&bursty);
        let peak = |values: &[f64]| values.iter().cloned().fold(0.0f64, f64::max);
        let mean = |values: &[f64]| values.iter().sum::<f64>() / values.len() as f64;
        assert!(peak(&bursty_envelope) / mean(&bursty_envelope).max(1e-9) > 5.0);
        assert!(
            peak(&steady_envelope) / mean(&steady_envelope).max(1e-9)
                < peak(&bursty_envelope) / mean(&bursty_envelope).max(1e-9)
        );
    }
}
