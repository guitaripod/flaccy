//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Equalizer/BiquadMath.swift`.
//!
//! Robert Bristow-Johnson's Audio EQ Cookbook, the single source of the
//! equalizer's maths on every client. Each formula keeps the Swift file's order
//! of operations, so the coefficients agree bit for bit on the same platform
//! libm, and the golden vectors below are the Swift test's own numbers.

use super::profile::EqualizerBand;
use serde::{Deserialize, Serialize};
use std::f64::consts::PI;

/// The five filter shapes the equalizer offers. Shelves and bells carry a gain;
/// the two pass filters only cut, so a gain on them is meaningless.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FilterType {
    Bell,
    LowShelf,
    HighShelf,
    HighPass,
    LowPass,
}

impl FilterType {
    /// Whether this shape takes a gain at all.
    pub fn has_gain(self) -> bool {
        self != FilterType::HighPass && self != FilterType::LowPass
    }

    /// The Q a freshly chosen type starts with: shelves and pass filters sit at
    /// the maximally flat 0.71, a bell at a musical 1.0.
    pub fn default_q(self) -> f64 {
        if self == FilterType::Bell {
            1.0
        } else {
            0.71
        }
    }
}

/// One second-order section, normalised by a0, in the form both the Swift and
/// the Rust DSP kernels run: `y = b0*x + z1`, `z1 = b1*x - a1*y + z2`,
/// `z2 = b2*x - a2*y`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Coefficients {
    pub b0: f64,
    pub b1: f64,
    pub b2: f64,
    pub a1: f64,
    pub a2: f64,
}

impl Coefficients {
    pub const IDENTITY: Coefficients = Coefficients {
        b0: 1.0,
        b1: 0.0,
        b2: 0.0,
        a1: 0.0,
        a2: 0.0,
    };

    /// The five values in the order the golden vectors list them.
    pub fn as_array(self) -> [f64; 5] {
        [self.b0, self.b1, self.b2, self.a1, self.a2]
    }
}

/// The cookbook formulas, the response of a section and the log axis the curve
/// is drawn on.
pub struct BiquadMath;

impl BiquadMath {
    /// The rate the curve is drawn at and the graphic solver is solved at.
    /// Playback recomputes coefficients at the file's own rate from the same
    /// filter gains.
    pub const REFERENCE_SAMPLE_RATE: f64 = 48_000.0;

    /// How close to Nyquist a centre frequency may sit before the cookbook's
    /// warping makes the response meaningless.
    const NYQUIST_FRACTION: f64 = 0.45;

    /// The normalised coefficients of one filter.
    pub fn coefficients(
        filter_type: FilterType,
        frequency: f64,
        gain: f64,
        q: f64,
        sample_rate: f64,
    ) -> Coefficients {
        let f = frequency.max(1.0).min(sample_rate * Self::NYQUIST_FRACTION);
        let w0 = 2.0 * PI * f / sample_rate;
        let cos_w = w0.cos();
        let sin_w = w0.sin();
        let alpha = sin_w / (2.0 * q.max(0.05));
        let a = 10f64.powf(gain / 40.0);

        let (b0, b1, b2, a0, a1, a2) = match filter_type {
            FilterType::Bell => (
                1.0 + alpha * a,
                -2.0 * cos_w,
                1.0 - alpha * a,
                1.0 + alpha / a,
                -2.0 * cos_w,
                1.0 - alpha / a,
            ),
            FilterType::LowShelf => {
                let s = 2.0 * a.sqrt() * alpha;
                (
                    a * ((a + 1.0) - (a - 1.0) * cos_w + s),
                    2.0 * a * ((a - 1.0) - (a + 1.0) * cos_w),
                    a * ((a + 1.0) - (a - 1.0) * cos_w - s),
                    (a + 1.0) + (a - 1.0) * cos_w + s,
                    -2.0 * ((a - 1.0) + (a + 1.0) * cos_w),
                    (a + 1.0) + (a - 1.0) * cos_w - s,
                )
            }
            FilterType::HighShelf => {
                let s = 2.0 * a.sqrt() * alpha;
                (
                    a * ((a + 1.0) + (a - 1.0) * cos_w + s),
                    -2.0 * a * ((a - 1.0) + (a + 1.0) * cos_w),
                    a * ((a + 1.0) + (a - 1.0) * cos_w - s),
                    (a + 1.0) - (a - 1.0) * cos_w + s,
                    2.0 * ((a - 1.0) - (a + 1.0) * cos_w),
                    (a + 1.0) - (a - 1.0) * cos_w - s,
                )
            }
            FilterType::HighPass => (
                (1.0 + cos_w) / 2.0,
                -(1.0 + cos_w),
                (1.0 + cos_w) / 2.0,
                1.0 + alpha,
                -2.0 * cos_w,
                1.0 - alpha,
            ),
            FilterType::LowPass => (
                (1.0 - cos_w) / 2.0,
                1.0 - cos_w,
                (1.0 - cos_w) / 2.0,
                1.0 + alpha,
                -2.0 * cos_w,
                1.0 - alpha,
            ),
        };
        Coefficients {
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0,
        }
    }

    /// The coefficients of a band, with the gain dropped for a pass filter.
    pub fn coefficients_for(band: &EqualizerBand, sample_rate: f64) -> Coefficients {
        let gain = if band.filter_type.has_gain() {
            band.gain
        } else {
            0.0
        };
        Self::coefficients(band.filter_type, band.frequency, gain, band.q, sample_rate)
    }

    /// Magnitude of one section at `frequency`, in decibels.
    pub fn magnitude_decibels(c: Coefficients, frequency: f64, sample_rate: f64) -> f64 {
        let w = 2.0 * PI * frequency / sample_rate;
        let cw = w.cos();
        let c2w = (2.0 * w).cos();
        let sw = w.sin();
        let s2w = (2.0 * w).sin();
        let nr = c.b0 + c.b1 * cw + c.b2 * c2w;
        let ni = -(c.b1 * sw + c.b2 * s2w);
        let dr = 1.0 + c.a1 * cw + c.a2 * c2w;
        let di = -(c.a1 * sw + c.a2 * s2w);
        let num = nr * nr + ni * ni;
        let den = dr * dr + di * di;
        10.0 * (num / den.max(1e-12)).max(1e-12).log10()
    }

    /// The summed response of every enabled band at `frequency`, in decibels,
    /// without any preamp, at the reference rate.
    pub fn response_decibels(bands: &[EqualizerBand], frequency: f64) -> f64 {
        let rate = Self::REFERENCE_SAMPLE_RATE;
        let mut sum = 0.0;
        for band in bands.iter().filter(|band| band.is_enabled) {
            sum += Self::magnitude_decibels(Self::coefficients_for(band, rate), frequency, rate);
        }
        sum
    }

    /// `count` frequencies spaced evenly on a log axis between 20 Hz and 20 kHz.
    pub fn log_frequencies(count: usize) -> Vec<f64> {
        let low = EqualizerBand::FREQUENCY_MIN;
        let high = EqualizerBand::FREQUENCY_MAX;
        if count <= 1 {
            return vec![low];
        }
        (0..count)
            .map(|i| low * (high / low).powf(i as f64 / (count - 1) as f64))
            .collect()
    }

    /// The response sampled on a log axis at the reference rate, ready to draw.
    pub fn curve(bands: &[EqualizerBand], points: usize) -> Vec<f64> {
        let rate = Self::REFERENCE_SAMPLE_RATE;
        let compiled: Vec<Coefficients> = bands
            .iter()
            .filter(|band| band.is_enabled)
            .map(|band| Self::coefficients_for(band, rate))
            .collect();
        Self::log_frequencies(points)
            .into_iter()
            .map(|f| {
                compiled
                    .iter()
                    .fold(0.0, |acc, c| acc + Self::magnitude_decibels(*c, f, rate))
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_coefficients(c: Coefficients, expected: [f64; 5]) {
        for (actual, expected) in c.as_array().iter().zip(expected.iter()) {
            assert!(
                (actual - expected).abs() <= 1e-12,
                "coefficient {actual} != {expected}"
            );
        }
    }

    #[test]
    fn bell_matches_the_cookbook() {
        let c = BiquadMath::coefficients(FilterType::Bell, 1_000.0, 6.0, 1.41, 48_000.0);
        assert_coefficients(
            c,
            [
                1.031577910616767,
                -1.919976143597597,
                0.904965631438766,
                -1.919976143597597,
                0.936543542055534,
            ],
        );
    }

    #[test]
    fn low_shelf_matches_the_cookbook() {
        let c = BiquadMath::coefficients(FilterType::LowShelf, 200.0, -4.0, 0.71, 44_100.0);
        assert_coefficients(
            c,
            [
                0.995379761918072,
                -1.955153384139738,
                0.960404321312953,
                -1.954968938337245,
                0.955968529033518,
            ],
        );
    }

    #[test]
    fn high_shelf_matches_the_cookbook() {
        let c = BiquadMath::coefficients(FilterType::HighShelf, 6_000.0, 3.0, 0.71, 96_000.0);
        assert_coefficients(
            c,
            [
                1.347599661698509,
                -2.019319747293779,
                0.810799478426938,
                -1.409259540929382,
                0.548338933761050,
            ],
        );
    }

    #[test]
    fn high_pass_matches_the_cookbook() {
        let c = BiquadMath::coefficients(FilterType::HighPass, 80.0, 0.0, 0.71, 48_000.0);
        assert_coefficients(
            c,
            [
                0.992652274596786,
                -1.985304549193571,
                0.992652274596786,
                -1.985250119947334,
                0.985358978439808,
            ],
        );
    }

    #[test]
    fn low_pass_matches_the_cookbook() {
        let c = BiquadMath::coefficients(FilterType::LowPass, 12_000.0, 0.0, 0.71, 48_000.0);
        assert_coefficients(
            c,
            [
                0.293388429752066,
                0.586776859504132,
                0.293388429752066,
                0.0,
                0.173553719008264,
            ],
        );
    }

    #[test]
    fn a_bell_reaches_its_gain_at_its_centre() {
        let c = BiquadMath::coefficients(FilterType::Bell, 1_000.0, 6.0, 1.41, 48_000.0);
        let heard = BiquadMath::magnitude_decibels(c, 1_000.0, 48_000.0);
        assert!((heard - 6.0).abs() <= 0.001, "{heard}");
    }

    #[test]
    fn shelves_settle_at_their_gain_on_their_own_side() {
        let low = BiquadMath::coefficients(FilterType::LowShelf, 200.0, 6.0, 0.71, 48_000.0);
        assert!((BiquadMath::magnitude_decibels(low, 20.0, 48_000.0) - 6.0).abs() <= 0.05);
        assert!((BiquadMath::magnitude_decibels(low, 20_000.0, 48_000.0) - 0.0).abs() <= 0.05);
        let high = BiquadMath::coefficients(FilterType::HighShelf, 4_000.0, 6.0, 0.71, 48_000.0);
        assert!((BiquadMath::magnitude_decibels(high, 20_000.0, 48_000.0) - 6.0).abs() <= 0.2);
    }

    #[test]
    fn a_pass_filter_is_three_decibels_down_at_its_corner_when_q_is_maximally_flat() {
        let c = BiquadMath::coefficients(FilterType::HighPass, 100.0, 0.0, 0.7071, 48_000.0);
        let heard = BiquadMath::magnitude_decibels(c, 100.0, 48_000.0);
        assert!((heard - -3.01).abs() <= 0.02, "{heard}");
    }
}
