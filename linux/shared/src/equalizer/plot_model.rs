//! Mirrors `Features/Equalizer/EqualizerPlotModel.swift`.
//!
//! The state behind the response curve: the bands to draw, the points to put on
//! them, and the easing that lets a preset glide into place and the spectrum
//! rise and fall rather than jump. Drawing and pointer handling stay in each
//! client's view. Coordinates grow downward.

use super::biquad::BiquadMath;
use super::graphic::GraphicSolver;
use super::plot::EqualizerPlot;
use super::profile::EqualizerBand;
use super::spectrum::SpectrumAnalyzer;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub fn min_x(&self) -> f64 {
        self.x
    }

    pub fn min_y(&self) -> f64 {
        self.y
    }

    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }

    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }

    pub fn contains(&self, point: Point) -> bool {
        point.x >= self.x && point.x <= self.max_x() && point.y >= self.y && point.y <= self.max_y()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlotMode {
    Simple,
    Advanced,
}

/// What a plot is asked to show.
#[derive(Clone, Debug, PartialEq)]
pub struct PlotContent {
    pub mode: PlotMode,
    pub targets: Vec<f64>,
    pub bands: Vec<EqualizerBand>,
    pub selected_index: usize,
    pub is_enabled: bool,
    pub is_comparing: bool,
}

impl Default for PlotContent {
    fn default() -> Self {
        Self {
            mode: PlotMode::Simple,
            targets: vec![0.0; GraphicSolver::CENTRES.len()],
            bands: Vec::new(),
            selected_index: 0,
            is_enabled: true,
            is_comparing: false,
        }
    }
}

pub struct PlotModel {
    content: PlotContent,
    display_targets: Vec<f64>,
    resolved_bands: Vec<EqualizerBand>,
    spectrum_bins: Vec<f32>,
    pub is_dragging: bool,
}

impl Default for PlotModel {
    fn default() -> Self {
        Self::new()
    }
}

impl PlotModel {
    pub const SPECTRUM_FLOOR_DECIBELS: f32 = -78.0;
    pub const SPECTRUM_RANGE_DECIBELS: f32 = 66.0;

    const EASING: f64 = 0.34;
    const SETTLE_THRESHOLD: f64 = 0.02;
    const SPECTRUM_FALL: f32 = 2.2;
    const SPECTRUM_DECAY: f32 = 3.0;

    pub fn new() -> Self {
        Self {
            content: PlotContent::default(),
            display_targets: vec![0.0; GraphicSolver::CENTRES.len()],
            resolved_bands: Vec::new(),
            spectrum_bins: Vec::new(),
            is_dragging: false,
        }
    }

    pub fn content(&self) -> &PlotContent {
        &self.content
    }

    pub fn display_targets(&self) -> &[f64] {
        &self.display_targets
    }

    pub fn resolved_bands(&self) -> &[EqualizerBand] {
        &self.resolved_bands
    }

    pub fn spectrum_bins(&self) -> &[f32] {
        &self.spectrum_bins
    }

    /// Replaces the content. In Simple mode the drawn targets glide to the new
    /// ones unless `snap` is set, as it is when the mode itself changed.
    pub fn update(&mut self, new: PlotContent, snap: bool) {
        let mode_changed = new.mode != self.content.mode;
        if new.mode == PlotMode::Simple && (snap || mode_changed) {
            self.display_targets = new.targets.clone();
        }
        self.content = new;
        self.refresh_resolved_bands();
    }

    /// One animation frame. Returns true when the drawn curve moved.
    pub fn step(&mut self, spectrum: Option<&[f32]>, freeze_spectrum: bool) -> bool {
        let mut moved = false;
        if self.content.mode == PlotMode::Simple {
            if self.is_dragging {
                if self.display_targets != self.content.targets {
                    self.display_targets = self.content.targets.clone();
                    moved = true;
                }
            } else {
                for index in 0..self.display_targets.len() {
                    let goal = self.content.targets.get(index).copied().unwrap_or(0.0);
                    let gap = goal - self.display_targets[index];
                    if gap.abs() < Self::SETTLE_THRESHOLD {
                        if self.display_targets[index] != goal {
                            self.display_targets[index] = goal;
                            moved = true;
                        }
                    } else {
                        self.display_targets[index] += gap * Self::EASING;
                        moved = true;
                    }
                }
            }
        }
        if moved {
            self.refresh_resolved_bands();
        }
        if !freeze_spectrum {
            self.advance_spectrum(spectrum);
        }
        moved
    }

    fn advance_spectrum(&mut self, fresh: Option<&[f32]>) {
        let Some(fresh) = fresh else {
            for bin in self.spectrum_bins.iter_mut() {
                *bin = (*bin - Self::SPECTRUM_DECAY).max(SpectrumAnalyzer::FLOOR_DECIBELS);
            }
            return;
        };
        if self.spectrum_bins.len() != fresh.len() {
            self.spectrum_bins = fresh.to_vec();
        }
        for (index, value) in fresh.iter().enumerate() {
            let current = self.spectrum_bins[index];
            self.spectrum_bins[index] = if *value > current {
                *value
            } else {
                value.max(current - Self::SPECTRUM_FALL)
            };
        }
    }

    fn refresh_resolved_bands(&mut self) {
        self.resolved_bands = match self.content.mode {
            PlotMode::Simple => GraphicSolver::bands_for_targets(&self.display_targets),
            PlotMode::Advanced => self.content.bands.clone(),
        };
    }

    pub fn node_count(&self) -> usize {
        match self.content.mode {
            PlotMode::Simple => GraphicSolver::CENTRES.len(),
            PlotMode::Advanced => self.content.bands.len(),
        }
    }

    pub fn node_position(&self, index: usize, plot: Rect) -> Point {
        match self.content.mode {
            PlotMode::Simple => Point {
                x: plot.min_x()
                    + EqualizerPlot::x_for_frequency(GraphicSolver::CENTRES[index], plot.width),
                y: plot.min_y()
                    + EqualizerPlot::y_for_decibels(self.display_targets[index], plot.height),
            },
            PlotMode::Advanced => {
                let band = &self.content.bands[index];
                let decibels = if band.filter_type.has_gain() {
                    band.gain
                } else {
                    0.0
                };
                Point {
                    x: plot.min_x() + EqualizerPlot::x_for_frequency(band.frequency, plot.width),
                    y: plot.min_y() + EqualizerPlot::y_for_decibels(decibels, plot.height),
                }
            }
        }
    }

    /// The curve of `bands`, sampled on a log axis and clamped a little past the plot.
    pub fn curve_points(&self, bands: &[EqualizerBand], plot: Rect, count: usize) -> Vec<Point> {
        let reference = BiquadMath::REFERENCE_SAMPLE_RATE;
        let compiled: Vec<_> = bands
            .iter()
            .filter(|band| band.is_enabled)
            .map(|band| BiquadMath::coefficients_for(band, reference))
            .collect();
        let limit = EqualizerPlot::DECIBEL_RANGE * 1.5;
        BiquadMath::log_frequencies(count)
            .into_iter()
            .map(|frequency| {
                let decibels: f64 = compiled
                    .iter()
                    .map(|c| BiquadMath::magnitude_decibels(*c, frequency, reference))
                    .sum();
                Point {
                    x: plot.min_x() + EqualizerPlot::x_for_frequency(frequency, plot.width),
                    y: plot.min_y()
                        + EqualizerPlot::y_for_decibels(
                            decibels.max(-limit).min(limit),
                            plot.height,
                        ),
                }
            })
            .collect()
    }

    /// The spectrum as points along the plot, left to right; the caller closes the shape.
    pub fn spectrum_points(&self, plot: Rect) -> Vec<Point> {
        if self.spectrum_bins.is_empty() {
            return Vec::new();
        }
        let low = EqualizerBand::FREQUENCY_MIN;
        let high = EqualizerBand::FREQUENCY_MAX;
        let count = self.spectrum_bins.len() as f64;
        self.spectrum_bins
            .iter()
            .enumerate()
            .map(|(index, level)| {
                let frequency = low * (high / low).powf((index as f64 + 0.5) / count);
                let fraction = ((*level - Self::SPECTRUM_FLOOR_DECIBELS)
                    / Self::SPECTRUM_RANGE_DECIBELS)
                    .max(0.0)
                    .min(1.0) as f64;
                Point {
                    x: plot.min_x() + EqualizerPlot::x_for_frequency(frequency, plot.width),
                    y: plot.max_y() - fraction * plot.height * 0.86,
                }
            })
            .collect()
    }

    /// The node nearest `point` within `radius`, if any.
    pub fn nearest_node(&self, point: Point, plot: Rect, radius: f64) -> Option<usize> {
        let mut best = None;
        let mut distance = radius;
        for index in 0..self.node_count() {
            let center = self.node_position(index, plot);
            let d = (center.x - point.x).hypot(center.y - point.y);
            if d < distance {
                distance = d;
                best = Some(index);
            }
        }
        best
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PLOT: Rect = Rect {
        x: 36.0,
        y: 18.0,
        width: 300.0,
        height: 200.0,
    };

    fn simple(targets: Vec<f64>) -> PlotContent {
        PlotContent {
            targets,
            ..PlotContent::default()
        }
    }

    #[test]
    fn a_simple_plot_has_ten_nodes_on_the_iso_centres() {
        let mut model = PlotModel::new();
        model.update(simple(vec![0.0; 10]), true);

        assert_eq!(model.node_count(), 10);
        let first = model.node_position(0, PLOT);
        let expected = PLOT.min_x() + EqualizerPlot::x_for_frequency(32.0, PLOT.width);
        assert!((first.x - expected).abs() < 1e-9);
        assert!((first.y - (PLOT.min_y() + PLOT.height / 2.0)).abs() < 1e-9);
    }

    #[test]
    fn drawn_targets_glide_to_new_ones_and_then_settle_exactly() {
        let mut model = PlotModel::new();
        model.update(simple(vec![0.0; 10]), true);
        let goal = vec![6.0, 5.0, 4.0, 2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
        model.update(simple(goal.clone()), false);

        assert_eq!(model.display_targets()[0], 0.0);
        assert!(model.step(None, true));
        assert!(model.display_targets()[0] > 0.0 && model.display_targets()[0] < 6.0);
        for _ in 0..40 {
            model.step(None, true);
        }
        assert_eq!(model.display_targets(), goal.as_slice());
        assert!(!model.step(None, true));
    }

    #[test]
    fn snapping_skips_the_glide() {
        let mut model = PlotModel::new();
        let goal = vec![3.0; 10];
        model.update(simple(goal.clone()), true);

        assert_eq!(model.display_targets(), goal.as_slice());
    }

    #[test]
    fn while_dragging_the_drawn_targets_follow_at_once() {
        let mut model = PlotModel::new();
        model.update(simple(vec![0.0; 10]), true);
        model.is_dragging = true;
        let mut dragged = vec![0.0; 10];
        dragged[3] = 4.5;
        model.update(simple(dragged.clone()), false);

        assert!(model.step(None, true));
        assert_eq!(model.display_targets(), dragged.as_slice());
    }

    #[test]
    fn the_spectrum_rises_at_once_and_falls_slowly() {
        let mut model = PlotModel::new();
        let loud = vec![-20.0_f32; 110];
        let quiet = vec![-80.0_f32; 110];
        model.step(Some(&loud), false);
        assert_eq!(model.spectrum_bins()[0], -20.0);

        model.step(Some(&quiet), false);
        assert!((model.spectrum_bins()[0] - (-22.2)).abs() < 1e-4);

        model.step(None, false);
        assert!((model.spectrum_bins()[0] - (-25.2)).abs() < 1e-4);
    }

    #[test]
    fn a_frozen_spectrum_does_not_move() {
        let mut model = PlotModel::new();
        model.step(Some(&vec![-30.0_f32; 110]), false);
        model.step(Some(&vec![-10.0_f32; 110]), true);

        assert_eq!(model.spectrum_bins()[5], -30.0);
    }

    #[test]
    fn the_nearest_node_must_be_inside_the_radius() {
        let mut model = PlotModel::new();
        model.update(simple(vec![0.0; 10]), true);
        let node = model.node_position(4, PLOT);

        assert_eq!(
            model.nearest_node(
                Point {
                    x: node.x + 5.0,
                    y: node.y
                },
                PLOT,
                32.0
            ),
            Some(4)
        );
        assert_eq!(
            model.nearest_node(
                Point {
                    x: node.x,
                    y: node.y + 90.0
                },
                PLOT,
                32.0
            ),
            None
        );
    }

    #[test]
    fn the_curve_of_a_flat_profile_runs_along_the_zero_line() {
        let model = PlotModel::new();
        let points = model.curve_points(&[], PLOT, 40);

        assert_eq!(points.len(), 40);
        assert!(points
            .iter()
            .all(|p| (p.y - (PLOT.min_y() + PLOT.height / 2.0)).abs() < 1e-9));
    }

    #[test]
    fn an_advanced_node_for_a_pass_filter_sits_on_the_zero_line() {
        let mut model = PlotModel::new();
        let content = PlotContent {
            mode: PlotMode::Advanced,
            bands: vec![EqualizerBand::new(
                super::super::biquad::FilterType::HighPass,
                80.0,
                9.0,
                None,
                true,
            )],
            ..PlotContent::default()
        };
        model.update(content, true);

        let node = model.node_position(0, PLOT);
        assert!((node.y - (PLOT.min_y() + PLOT.height / 2.0)).abs() < 1e-9);
    }
}
