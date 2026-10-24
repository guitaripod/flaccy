//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Equalizer/EqualizerPlot.swift`.
//!
//! How the equalizer's response curve maps onto a drawing surface, and how a
//! touch or a pointer maps back onto the numbers: 20 Hz to 20 kHz on a log
//! axis, plus or minus 12 dB on a linear one.

use super::graphic::GraphicSolver;
use super::profile::EqualizerBand;

/// The plot's axes and the gain settling rules a touch or pointer obeys.
pub struct EqualizerPlot;

impl EqualizerPlot {
    pub const DECIBEL_RANGE: f64 = 12.0;
    pub const MAGNET_THRESHOLD: f64 = 0.4;
    pub const GAIN_STEP: f64 = 0.5;
    pub const FINE_GAIN_STEP: f64 = 0.1;

    /// The horizontal position of `frequency` across a plot `width` wide.
    pub fn x_for_frequency(frequency: f64, width: f64) -> f64 {
        let low = EqualizerBand::FREQUENCY_MIN;
        let high = EqualizerBand::FREQUENCY_MAX;
        width * (frequency / low).ln() / (high / low).ln()
    }

    /// The frequency under a horizontal position, clamped to the plot.
    pub fn frequency_at_x(x: f64, width: f64) -> f64 {
        let low = EqualizerBand::FREQUENCY_MIN;
        let high = EqualizerBand::FREQUENCY_MAX;
        let fraction = (x / width).max(0.0).min(1.0);
        low * (high / low).powf(fraction)
    }

    /// Top of the plot is +12 dB, the middle is 0, the bottom is -12 dB.
    pub fn y_for_decibels(decibels: f64, height: f64) -> f64 {
        height / 2.0 - (decibels / Self::DECIBEL_RANGE) * (height / 2.0)
    }

    /// The gain under a vertical position, the inverse of `y_for_decibels`.
    pub fn decibels_at_y(y: f64, height: f64) -> f64 {
        (height / 2.0 - y) / (height / 2.0) * Self::DECIBEL_RANGE
    }

    /// A gain read off a touch, settled onto the half-decibel grid, with a
    /// magnet at 0 dB so flat is easy to find and easy to return to.
    pub fn snapped_gain(decibels: f64) -> f64 {
        if decibels.abs() < Self::MAGNET_THRESHOLD {
            return 0.0;
        }
        let stepped = (decibels / Self::GAIN_STEP).round() * Self::GAIN_STEP;
        stepped
            .max(EqualizerBand::GAIN_MIN)
            .min(EqualizerBand::GAIN_MAX)
    }

    /// A gain read off a touch for a parametric band, settled onto a tenth of a decibel.
    pub fn precise_gain(decibels: f64) -> f64 {
        if decibels.abs() < 0.3 {
            return 0.0;
        }
        let stepped = (decibels * 10.0).round() / 10.0;
        stepped
            .max(EqualizerBand::GAIN_MIN)
            .min(EqualizerBand::GAIN_MAX)
    }

    /// The index of the graphic band whose column a horizontal position falls in.
    pub fn nearest_centre_index(x: f64, width: f64) -> usize {
        let mut best = 0;
        let mut distance = f64::INFINITY;
        for (index, &centre) in GraphicSolver::CENTRES.iter().enumerate() {
            let d = (Self::x_for_frequency(centre, width) - x).abs();
            if d < distance {
                distance = d;
                best = index;
            }
        }
        best
    }

    /// A rounded frequency for a parametric band: three significant figures
    /// so a drag does not land on 1003.7 Hz.
    pub fn rounded_frequency(frequency: f64) -> f64 {
        let clamped = frequency
            .max(EqualizerBand::FREQUENCY_MIN)
            .min(EqualizerBand::FREQUENCY_MAX);
        let magnitude = 10f64.powf(clamped.log10().floor() - 2.0);
        (clamped / magnitude).round() * magnitude
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(actual: f64, expected: f64, tolerance: f64) -> bool {
        (actual - expected).abs() <= tolerance
    }

    #[test]
    fn the_axis_runs_from_twenty_hertz_to_twenty_kilohertz() {
        assert!(close(
            EqualizerPlot::x_for_frequency(20.0, 800.0),
            0.0,
            1e-9
        ));
        assert!(close(
            EqualizerPlot::x_for_frequency(20_000.0, 800.0),
            800.0,
            1e-9
        ));
        assert!(close(
            EqualizerPlot::x_for_frequency(632.455_532, 800.0),
            400.0,
            1e-3
        ));
    }

    #[test]
    fn frequency_and_position_round_trip() {
        for frequency in [20.0, 64.0, 440.0, 1_000.0, 8_000.0, 20_000.0] {
            let x = EqualizerPlot::x_for_frequency(frequency, 612.0);
            assert!(close(
                EqualizerPlot::frequency_at_x(x, 612.0),
                frequency,
                frequency * 1e-9
            ));
        }
    }

    #[test]
    fn a_position_outside_the_plot_is_clamped() {
        assert!(close(
            EqualizerPlot::frequency_at_x(-50.0, 300.0),
            20.0,
            1e-9
        ));
        assert!(close(
            EqualizerPlot::frequency_at_x(900.0, 300.0),
            20_000.0,
            1e-6
        ));
    }

    #[test]
    fn the_vertical_axis_runs_plus_to_minus_twelve() {
        assert!(close(EqualizerPlot::y_for_decibels(12.0, 200.0), 0.0, 1e-9));
        assert!(close(
            EqualizerPlot::y_for_decibels(0.0, 200.0),
            100.0,
            1e-9
        ));
        assert!(close(
            EqualizerPlot::y_for_decibels(-12.0, 200.0),
            200.0,
            1e-9
        ));
        assert!(close(EqualizerPlot::decibels_at_y(25.0, 200.0), 9.0, 1e-9));
    }

    #[test]
    fn a_gain_settles_on_half_decibels_with_a_magnet_at_zero() {
        assert_eq!(EqualizerPlot::snapped_gain(0.3), 0.0);
        assert_eq!(EqualizerPlot::snapped_gain(-0.39), 0.0);
        assert_eq!(EqualizerPlot::snapped_gain(0.6), 0.5);
        assert_eq!(EqualizerPlot::snapped_gain(3.8), 4.0);
        assert_eq!(EqualizerPlot::snapped_gain(-7.2), -7.0);
        assert_eq!(EqualizerPlot::snapped_gain(40.0), 12.0);
        assert_eq!(EqualizerPlot::snapped_gain(-40.0), -12.0);
    }

    #[test]
    fn a_parametric_gain_settles_on_tenths_of_a_decibel() {
        assert_eq!(EqualizerPlot::precise_gain(0.2), 0.0);
        assert_eq!(EqualizerPlot::precise_gain(2.34), 2.3);
        assert_eq!(EqualizerPlot::precise_gain(-11.96), -12.0);
    }

    #[test]
    fn a_touch_finds_the_column_it_is_in() {
        let width = 600.0;
        for (index, &centre) in GraphicSolver::CENTRES.iter().enumerate() {
            let x = EqualizerPlot::x_for_frequency(centre, width);
            assert_eq!(EqualizerPlot::nearest_centre_index(x + 3.0, width), index);
        }
        assert_eq!(EqualizerPlot::nearest_centre_index(-20.0, width), 0);
        assert_eq!(EqualizerPlot::nearest_centre_index(900.0, width), 9);
    }

    #[test]
    fn a_frequency_keeps_three_significant_figures() {
        assert!(close(
            EqualizerPlot::rounded_frequency(1_003.7),
            1_000.0,
            1e-9
        ));
        assert!(close(EqualizerPlot::rounded_frequency(47.34), 47.3, 1e-9));
        assert!(close(
            EqualizerPlot::rounded_frequency(12_345.0),
            12_300.0,
            1e-9
        ));
        assert!(close(EqualizerPlot::rounded_frequency(5.0), 20.0, 1e-9));
        assert!(close(
            EqualizerPlot::rounded_frequency(40_000.0),
            20_000.0,
            1e-9
        ));
    }
}
