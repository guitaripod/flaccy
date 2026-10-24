//! Mirrors `Features/Equalizer/EqualizerPlotInteraction.swift`.
//!
//! How a pointer edits the curve, written once for every client. In Simple mode
//! a press grabs the column it lands in and moves that band straight up and
//! down; in Advanced mode it grabs the node under it and moves it in both
//! directions, and a double press on empty space adds a band. A double press on
//! a node resets its gain. Values settle through `EqualizerPlot`, so every
//! client lands on the same numbers. The state machine returns the actions a
//! view should apply instead of calling back, which keeps it free of any toolkit.

use super::plot::EqualizerPlot;
use super::plot_model::{PlotMode, PlotModel, Point, Rect};
use super::profile::EqualizerBand;

/// The moments of a drag a client may want to mark with feedback.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Detent {
    Tick,
    Zero,
    Limit,
    Reset,
    Add,
}

#[derive(Clone, Debug, PartialEq)]
pub enum PlotAction {
    BeginEditing(usize),
    SetTarget {
        value: f64,
        index: usize,
    },
    SetFrequencyAndGain {
        frequency: f64,
        gain: f64,
        index: usize,
    },
    ResetBand(usize),
    AddBand {
        frequency: f64,
        gain: f64,
    },
    Cross(Detent),
    Ended,
}

#[derive(Clone, Copy)]
struct Press {
    time: f64,
    index: Option<usize>,
    point: Point,
}

pub struct PlotInteraction {
    is_active: bool,
    dragged_index: usize,
    last_value: f64,
    last_press: Option<Press>,
    pub node_hit_radius: f64,
}

impl Default for PlotInteraction {
    fn default() -> Self {
        Self::new()
    }
}

impl PlotInteraction {
    const DOUBLE_WINDOW: f64 = 0.32;
    const DOUBLE_SLOP: f64 = 24.0;
    const DEFAULT_HIT_RADIUS: f64 = 32.0;

    pub fn new() -> Self {
        Self {
            is_active: false,
            dragged_index: 0,
            last_value: 0.0,
            last_press: None,
            node_hit_radius: Self::DEFAULT_HIT_RADIUS,
        }
    }

    pub fn is_active(&self) -> bool {
        self.is_active
    }

    pub fn begin(
        &mut self,
        model: &mut PlotModel,
        point: Point,
        plot: Rect,
        time: f64,
    ) -> Vec<PlotAction> {
        let local_x = point.x - plot.min_x();
        let local_y = point.y - plot.min_y();
        let mut actions = Vec::new();

        match model.content().mode {
            PlotMode::Simple => {
                let index = EqualizerPlot::nearest_centre_index(local_x, plot.width);
                let is_double = self
                    .last_press
                    .map(|press| time - press.time < Self::DOUBLE_WINDOW && press.index == Some(index))
                    .unwrap_or(false);
                self.last_press = Some(Press {
                    time,
                    index: Some(index),
                    point,
                });
                actions.push(PlotAction::BeginEditing(index));
                if is_double {
                    actions.push(PlotAction::Cross(Detent::Reset));
                    actions.push(PlotAction::ResetBand(index));
                    return actions;
                }
                self.start_dragging(model, index);
                let value = EqualizerPlot::snapped_gain(EqualizerPlot::decibels_at_y(
                    local_y,
                    plot.height,
                ));
                self.last_value = value;
                actions.push(PlotAction::SetTarget { value, index });
            }
            PlotMode::Advanced => {
                let hit = model.nearest_node(point, plot, self.node_hit_radius);
                let is_double = self
                    .last_press
                    .map(|press| {
                        time - press.time < Self::DOUBLE_WINDOW
                            && (press.point.x - point.x).hypot(press.point.y - point.y)
                                < Self::DOUBLE_SLOP
                    })
                    .unwrap_or(false);
                self.last_press = Some(Press {
                    time,
                    index: hit,
                    point,
                });
                if let Some(hit) = hit {
                    actions.push(PlotAction::BeginEditing(hit));
                    let has_gain = model.content().bands[hit].filter_type.has_gain();
                    if is_double && has_gain {
                        actions.push(PlotAction::Cross(Detent::Reset));
                        actions.push(PlotAction::ResetBand(hit));
                        return actions;
                    }
                    self.start_dragging(model, hit);
                    self.last_value = model.content().bands[hit].gain;
                } else if is_double && plot.contains(point) {
                    let frequency = EqualizerPlot::rounded_frequency(
                        EqualizerPlot::frequency_at_x(local_x, plot.width),
                    );
                    let gain = EqualizerPlot::precise_gain(EqualizerPlot::decibels_at_y(
                        local_y,
                        plot.height,
                    ));
                    actions.push(PlotAction::Cross(Detent::Add));
                    actions.push(PlotAction::AddBand { frequency, gain });
                    let new_index = model.content().bands.len();
                    self.start_dragging(model, new_index);
                    self.last_value = gain;
                }
            }
        }
        actions
    }

    pub fn move_to(&mut self, model: &PlotModel, point: Point, plot: Rect) -> Vec<PlotAction> {
        if !self.is_active {
            return Vec::new();
        }
        let local_x = point.x - plot.min_x();
        let decibels = EqualizerPlot::decibels_at_y(point.y - plot.min_y(), plot.height);
        let mut actions = Vec::new();

        match model.content().mode {
            PlotMode::Simple => {
                let value = EqualizerPlot::snapped_gain(decibels);
                if value == self.last_value {
                    return actions;
                }
                if let Some(detent) = Self::detent(self.last_value, value) {
                    actions.push(PlotAction::Cross(detent));
                }
                self.last_value = value;
                actions.push(PlotAction::SetTarget {
                    value,
                    index: self.dragged_index,
                });
            }
            PlotMode::Advanced => {
                let Some(band) = model.content().bands.get(self.dragged_index) else {
                    return actions;
                };
                let frequency = EqualizerPlot::rounded_frequency(EqualizerPlot::frequency_at_x(
                    local_x, plot.width,
                ));
                let has_gain = band.filter_type.has_gain();
                let gain = if has_gain {
                    EqualizerPlot::precise_gain(decibels)
                } else {
                    0.0
                };
                if has_gain {
                    if let Some(detent) = Self::detent(self.last_value, gain) {
                        actions.push(PlotAction::Cross(detent));
                    }
                }
                self.last_value = gain;
                actions.push(PlotAction::SetFrequencyAndGain {
                    frequency,
                    gain,
                    index: self.dragged_index,
                });
            }
        }
        actions
    }

    pub fn end(&mut self, model: &mut PlotModel) -> Vec<PlotAction> {
        if !self.is_active {
            return Vec::new();
        }
        self.is_active = false;
        model.is_dragging = false;
        vec![PlotAction::Ended]
    }

    fn start_dragging(&mut self, model: &mut PlotModel, index: usize) {
        self.is_active = true;
        model.is_dragging = true;
        self.dragged_index = index;
    }

    fn detent(old: f64, new: f64) -> Option<Detent> {
        let limit = EqualizerBand::GAIN_MAX;
        if new == 0.0 && old != 0.0 {
            Some(Detent::Zero)
        } else if new.abs() == limit && old.abs() != limit {
            Some(Detent::Limit)
        } else if new.floor() != old.floor() {
            Some(Detent::Tick)
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::biquad::FilterType;
    use super::super::graphic::GraphicSolver;
    use super::super::plot_model::PlotContent;
    use super::*;

    const PLOT: Rect = Rect {
        x: 36.0,
        y: 18.0,
        width: 300.0,
        height: 200.0,
    };

    fn simple_model() -> PlotModel {
        let mut model = PlotModel::new();
        model.update(PlotContent::default(), true);
        model
    }

    fn advanced_model(bands: Vec<EqualizerBand>) -> PlotModel {
        let mut model = PlotModel::new();
        model.update(
            PlotContent {
                mode: PlotMode::Advanced,
                bands,
                ..PlotContent::default()
            },
            true,
        );
        model
    }

    fn column(index: usize) -> f64 {
        PLOT.min_x() + EqualizerPlot::x_for_frequency(GraphicSolver::CENTRES[index], PLOT.width)
    }

    fn y_for(decibels: f64) -> f64 {
        PLOT.min_y() + EqualizerPlot::y_for_decibels(decibels, PLOT.height)
    }

    #[test]
    fn pressing_a_column_grabs_it_and_sets_its_gain_from_the_height() {
        let mut model = simple_model();
        let mut interaction = PlotInteraction::new();

        let actions = interaction.begin(
            &mut model,
            Point {
                x: column(3) + 4.0,
                y: y_for(6.1),
            },
            PLOT,
            1.0,
        );

        assert_eq!(
            actions,
            vec![
                PlotAction::BeginEditing(3),
                PlotAction::SetTarget {
                    value: 6.0,
                    index: 3
                }
            ]
        );
        assert!(interaction.is_active());
        assert!(model.is_dragging);
    }

    #[test]
    fn dragging_keeps_the_band_it_grabbed_and_marks_the_detents() {
        let mut model = simple_model();
        let mut interaction = PlotInteraction::new();
        interaction.begin(
            &mut model,
            Point {
                x: column(5),
                y: y_for(2.0),
            },
            PLOT,
            1.0,
        );

        let across = interaction.move_to(
            &model,
            Point {
                x: column(9),
                y: y_for(3.2),
            },
            PLOT,
        );
        let to_zero = interaction.move_to(
            &model,
            Point {
                x: column(9),
                y: y_for(0.1),
            },
            PLOT,
        );
        let to_limit = interaction.move_to(
            &model,
            Point {
                x: column(9),
                y: y_for(11.9),
            },
            PLOT,
        );

        assert_eq!(
            across,
            vec![
                PlotAction::Cross(Detent::Tick),
                PlotAction::SetTarget {
                    value: 3.0,
                    index: 5
                }
            ]
        );
        assert_eq!(
            to_zero,
            vec![
                PlotAction::Cross(Detent::Zero),
                PlotAction::SetTarget {
                    value: 0.0,
                    index: 5
                }
            ]
        );
        assert_eq!(
            to_limit,
            vec![
                PlotAction::Cross(Detent::Limit),
                PlotAction::SetTarget {
                    value: 12.0,
                    index: 5
                }
            ]
        );
    }

    #[test]
    fn a_move_that_changes_nothing_says_nothing() {
        let mut model = simple_model();
        let mut interaction = PlotInteraction::new();
        interaction.begin(
            &mut model,
            Point {
                x: column(2),
                y: y_for(4.0),
            },
            PLOT,
            1.0,
        );

        let actions = interaction.move_to(
            &model,
            Point {
                x: column(2),
                y: y_for(4.1),
            },
            PLOT,
        );

        assert!(actions.is_empty());
    }

    #[test]
    fn a_double_press_on_a_column_resets_it_instead_of_dragging() {
        let mut model = simple_model();
        let mut interaction = PlotInteraction::new();
        let point = Point {
            x: column(4),
            y: y_for(5.0),
        };
        interaction.begin(&mut model, point, PLOT, 1.0);
        interaction.end(&mut model);

        let actions = interaction.begin(&mut model, point, PLOT, 1.2);

        assert_eq!(
            actions,
            vec![
                PlotAction::BeginEditing(4),
                PlotAction::Cross(Detent::Reset),
                PlotAction::ResetBand(4)
            ]
        );
        assert!(!interaction.is_active());
    }

    #[test]
    fn two_presses_too_far_apart_in_time_are_not_a_double() {
        let mut model = simple_model();
        let mut interaction = PlotInteraction::new();
        let point = Point {
            x: column(4),
            y: y_for(5.0),
        };
        interaction.begin(&mut model, point, PLOT, 1.0);
        interaction.end(&mut model);

        let actions = interaction.begin(&mut model, point, PLOT, 1.5);

        assert!(matches!(actions[1], PlotAction::SetTarget { .. }));
    }

    #[test]
    fn ending_reports_once_and_clears_the_dragging_flag() {
        let mut model = simple_model();
        let mut interaction = PlotInteraction::new();
        interaction.begin(
            &mut model,
            Point {
                x: column(0),
                y: y_for(1.0),
            },
            PLOT,
            1.0,
        );

        assert_eq!(interaction.end(&mut model), vec![PlotAction::Ended]);
        assert!(!model.is_dragging);
        assert!(interaction.end(&mut model).is_empty());
    }

    #[test]
    fn in_advanced_a_press_on_a_node_drags_both_axes_to_rounded_values() {
        let band = EqualizerBand::new(FilterType::Bell, 1_000.0, 3.0, Some(1.0), true);
        let mut model = advanced_model(vec![band]);
        let mut interaction = PlotInteraction::new();
        let node = model.node_position(0, PLOT);

        let begin = interaction.begin(&mut model, node, PLOT, 1.0);
        let moved = interaction.move_to(
            &model,
            Point {
                x: PLOT.min_x() + EqualizerPlot::x_for_frequency(2_003.0, PLOT.width),
                y: y_for(-2.34),
            },
            PLOT,
        );

        assert_eq!(begin, vec![PlotAction::BeginEditing(0)]);
        let PlotAction::SetFrequencyAndGain {
            frequency,
            gain,
            index,
        } = moved.last().cloned().unwrap()
        else {
            panic!("expected a frequency and gain update");
        };
        assert_eq!(index, 0);
        assert!((frequency - 2_000.0).abs() < 1e-9);
        assert!((gain - (-2.3)).abs() < 1e-9);
    }

    #[test]
    fn in_advanced_a_pass_filter_moves_sideways_only() {
        let band = EqualizerBand::new(FilterType::HighPass, 80.0, 0.0, None, true);
        let mut model = advanced_model(vec![band]);
        let mut interaction = PlotInteraction::new();
        let node = model.node_position(0, PLOT);
        interaction.begin(&mut model, node, PLOT, 1.0);

        let moved = interaction.move_to(
            &model,
            Point {
                x: node.x + 40.0,
                y: y_for(8.0),
            },
            PLOT,
        );

        let PlotAction::SetFrequencyAndGain { gain, .. } = moved.last().cloned().unwrap() else {
            panic!("expected an update");
        };
        assert_eq!(gain, 0.0);
        assert!(!moved.iter().any(|action| matches!(action, PlotAction::Cross(_))));
    }

    #[test]
    fn in_advanced_a_double_press_on_empty_space_adds_a_band_there() {
        let band = EqualizerBand::new(FilterType::Bell, 100.0, 0.0, None, true);
        let mut model = advanced_model(vec![band]);
        let mut interaction = PlotInteraction::new();
        let point = Point {
            x: PLOT.min_x() + EqualizerPlot::x_for_frequency(5_000.0, PLOT.width),
            y: y_for(4.0),
        };
        interaction.begin(&mut model, point, PLOT, 1.0);
        interaction.end(&mut model);

        let actions = interaction.begin(&mut model, point, PLOT, 1.1);

        assert_eq!(actions[0], PlotAction::Cross(Detent::Add));
        let PlotAction::AddBand { frequency, gain } = actions[1].clone() else {
            panic!("expected a new band");
        };
        assert!((frequency - 5_000.0).abs() < 60.0);
        assert_eq!(gain, 4.0);
        assert!(interaction.is_active());
    }

    #[test]
    fn in_advanced_a_double_press_on_a_node_resets_its_gain() {
        let band = EqualizerBand::new(FilterType::Bell, 1_000.0, 5.0, Some(1.0), true);
        let mut model = advanced_model(vec![band]);
        let mut interaction = PlotInteraction::new();
        let node = model.node_position(0, PLOT);
        interaction.begin(&mut model, node, PLOT, 1.0);
        interaction.end(&mut model);

        let actions = interaction.begin(&mut model, node, PLOT, 1.15);

        assert_eq!(
            actions,
            vec![
                PlotAction::BeginEditing(0),
                PlotAction::Cross(Detent::Reset),
                PlotAction::ResetBand(0)
            ]
        );
    }

    #[test]
    fn in_advanced_a_single_press_on_empty_space_does_nothing() {
        let mut model = advanced_model(vec![EqualizerBand::new(
            FilterType::Bell,
            100.0,
            0.0,
            None,
            true,
        )]);
        let mut interaction = PlotInteraction::new();

        let actions = interaction.begin(
            &mut model,
            Point {
                x: PLOT.min_x() + EqualizerPlot::x_for_frequency(9_000.0, PLOT.width),
                y: y_for(7.0),
            },
            PLOT,
            1.0,
        );

        assert!(actions.is_empty());
        assert!(!interaction.is_active());
    }
}
