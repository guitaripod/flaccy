//! Draws the response curve with Cairo, operation for operation as
//! `Features/Equalizer/EqualizerPlotRenderer.swift` does with Core Graphics: the grid, the
//! live spectrum behind the curve, the filled and glowing line, the active
//! column, the nodes and the value bubble. Cairo has no shadows, so a glow is
//! a few wider, fainter strokes under the line.

use flaccy_shared::equalizer::graphic::GraphicSolver;
use flaccy_shared::equalizer::plot::EqualizerPlot;
use flaccy_shared::equalizer::plot_model::{PlotMode, PlotModel, Point, Rect};
use gtk::cairo::{self, Context, FontSlant, FontWeight, LinearGradient, RadialGradient};
use std::f64::consts::PI;

use super::copy;

pub type Rgb = (f64, f64, f64);

pub const LOSSLESS: Rgb = (0.37, 0.83, 0.88);
pub const CAUTION: Rgb = (1.0, 0.71, 0.33);
pub const DANGER: Rgb = (1.0, 0.42, 0.45);
pub const CUT: Rgb = (0.56, 0.64, 1.0);

pub const BAND_COLORS: [Rgb; 10] = [
    (1.00, 0.48, 0.56),
    (1.00, 0.64, 0.36),
    (0.95, 0.83, 0.36),
    (0.61, 0.90, 0.39),
    (0.31, 0.88, 0.69),
    (0.29, 0.78, 0.94),
    (0.49, 0.61, 1.00),
    (0.71, 0.54, 1.00),
    (0.91, 0.52, 0.94),
    (1.00, 0.52, 0.75),
];

pub fn band_color(index: usize) -> Rgb {
    BAND_COLORS[index % BAND_COLORS.len()]
}

/// A band colour as CSS, for the table's index column.
pub fn band_color_css(index: usize) -> String {
    rgb_css(band_color(index))
}

pub fn rgb_css((r, g, b): Rgb) -> String {
    format!(
        "#{:02x}{:02x}{:02x}",
        (r * 255.0).round() as u8,
        (g * 255.0).round() as u8,
        (b * 255.0).round() as u8
    )
}

/// How a plot is painted this frame.
#[derive(Clone, Copy)]
pub struct Style {
    pub accent: Rgb,
    pub ink: Rgb,
    pub is_dark: bool,
    pub is_enabled: bool,
    pub is_comparing: bool,
    pub scale: f64,
}

fn source(cr: &Context, color: Rgb, alpha: f64) {
    cr.set_source_rgba(color.0, color.1, color.2, alpha);
}

fn rounded_rectangle(cr: &Context, x: f64, y: f64, width: f64, height: f64, radius: f64) {
    let radius = radius.min(width / 2.0).min(height / 2.0);
    cr.new_sub_path();
    cr.arc(x + width - radius, y + radius, radius, -PI / 2.0, 0.0);
    cr.arc(x + width - radius, y + height - radius, radius, 0.0, PI / 2.0);
    cr.arc(x + radius, y + height - radius, radius, PI / 2.0, PI);
    cr.arc(x + radius, y + radius, radius, PI, 3.0 * PI / 2.0);
    cr.close_path();
}

fn disc(cr: &Context, x: f64, y: f64, radius: f64) {
    cr.new_sub_path();
    cr.arc(x, y, radius, 0.0, 2.0 * PI);
}

#[derive(Clone, Copy, PartialEq)]
pub enum Anchor {
    Center,
    Trailing,
}

fn use_font(cr: &Context, size: f64, bold: bool) {
    cr.select_font_face(
        "Sans",
        FontSlant::Normal,
        if bold { FontWeight::Bold } else { FontWeight::Normal },
    );
    cr.set_font_size(size);
}

pub fn text_width(cr: &Context, text: &str, size: f64, bold: bool) -> f64 {
    use_font(cr, size, bold);
    cr.text_extents(text).map(|extents| extents.x_advance()).unwrap_or(0.0)
}

/// Draws `text` with its vertical centre on `y`, the way the Core Text helper
/// centres a line on the point it is given.
pub fn draw_text(
    cr: &Context,
    text: &str,
    x: f64,
    y: f64,
    anchor: Anchor,
    size: f64,
    bold: bool,
    color: Rgb,
    alpha: f64,
) {
    use_font(cr, size, bold);
    let width = cr.text_extents(text).map(|extents| extents.x_advance()).unwrap_or(0.0);
    let (ascent, descent) = cr
        .font_extents()
        .map(|extents| (extents.ascent(), extents.descent()))
        .unwrap_or((size, 0.0));
    let left = match anchor {
        Anchor::Center => x - width / 2.0,
        Anchor::Trailing => x - width,
    };
    source(cr, color, alpha);
    cr.move_to(left, y + (ascent - descent) / 2.0);
    let _ = cr.show_text(text);
}

/// Everything the renderer needs besides the model.
pub struct PlotFrame<'a> {
    pub width: f64,
    pub plot: Rect,
    pub model: &'a PlotModel,
    pub style: Style,
    pub hover: Option<usize>,
    pub shows_focus: bool,
    /// The curve of a preset being auditioned, already placed on the plot. It
    /// is drawn as the line being heard, with the curve in force left behind
    /// as a thin dashed reference.
    pub preview: Option<&'a [Point]>,
}

pub fn draw(cr: &Context, frame: &PlotFrame) {
    let PlotFrame { plot, model, style, .. } = *frame;
    draw_grid(cr, plot, &style);

    let _ = cr.save();
    cr.push_group();
    draw_spectrum(cr, plot, model, &style);
    if model.content().mode == PlotMode::Advanced {
        draw_selected_band(cr, plot, model);
    }
    draw_curve(cr, plot, model, &style, frame.preview);
    let _ = cr.pop_group_to_source();
    let _ = cr.paint_with_alpha(if style.is_enabled || frame.preview.is_some() { 1.0 } else { 0.45 });
    let _ = cr.restore();

    if model.content().mode == PlotMode::Simple {
        draw_active_column(cr, plot, model, &style);
    }
    let _ = cr.save();
    cr.push_group();
    draw_nodes(cr, plot, model, &style, frame.hover);
    let _ = cr.pop_group_to_source();
    let _ = cr.paint_with_alpha(if frame.preview.is_some() {
        0.22
    } else if style.is_enabled {
        1.0
    } else {
        0.5
    });
    let _ = cr.restore();
    if model.is_dragging {
        draw_bubble(cr, frame);
    }
    draw_frequency_labels(cr, plot, model, &style);
    if frame.shows_focus {
        draw_focus_ring(cr, plot, model, &style);
    }
}

fn draw_grid(cr: &Context, plot: Rect, style: &Style) {
    let k = style.scale;
    let ink = style.ink;
    for decibels in [12.0, 6.0, 0.0, -6.0, -12.0] {
        let y = plot.min_y() + EqualizerPlot::y_for_decibels(decibels, plot.height);
        if decibels == 0.0 || decibels == 6.0 || decibels == -6.0 {
            let alpha = if decibels == 0.0 { 0.26 } else { 0.07 };
            source(cr, ink, alpha);
            cr.set_line_width(1.0);
            cr.move_to(plot.min_x(), y.round() + 0.5);
            cr.line_to(plot.max_x(), y.round() + 0.5);
            let _ = cr.stroke();
        }
        let label = if decibels > 0.0 {
            format!("+{}", decibels as i32)
        } else if decibels < 0.0 {
            format!("\u{2212}{}", decibels.abs() as i32)
        } else {
            "0".to_string()
        };
        draw_text(cr, &label, plot.min_x() - 6.0 * k, y, Anchor::Trailing, 10.0 * k, false, ink, 0.42);
    }
    for frequency in [100.0, 1_000.0, 10_000.0] {
        let x = plot.min_x() + EqualizerPlot::x_for_frequency(frequency, plot.width);
        source(cr, ink, 0.07);
        cr.set_line_width(1.0);
        cr.move_to(x.round() + 0.5, plot.min_y());
        cr.line_to(x.round() + 0.5, plot.max_y());
        let _ = cr.stroke();
    }
}

fn draw_frequency_labels(cr: &Context, plot: Rect, model: &PlotModel, style: &Style) {
    let k = style.scale;
    let active = if model.content().mode == PlotMode::Simple {
        Some(model.content().selected_index)
    } else {
        None
    };
    for (index, &centre) in GraphicSolver::CENTRES.iter().enumerate() {
        let is_active = Some(index) == active;
        let x = plot.min_x() + EqualizerPlot::x_for_frequency(centre, plot.width);
        draw_text(
            cr,
            &copy::short_hertz(centre),
            x,
            plot.max_y() + 17.0 * k,
            Anchor::Center,
            10.5 * k,
            is_active,
            style.ink,
            if is_active { 1.0 } else { 0.42 },
        );
    }
}

fn draw_spectrum(cr: &Context, plot: Rect, model: &PlotModel, style: &Style) {
    let points = model.spectrum_points(plot);
    if points.is_empty() {
        return;
    }
    let _ = cr.save();
    cr.move_to(plot.min_x(), plot.max_y());
    for point in &points {
        cr.line_to(point.x, point.y);
    }
    cr.line_to(plot.max_x(), plot.max_y());
    cr.close_path();
    cr.clip();
    let gradient = LinearGradient::new(0.0, plot.min_y(), 0.0, plot.max_y());
    let (r, g, b) = style.ink;
    let boost = if style.is_dark { 1.0 } else { 0.8 };
    gradient.add_color_stop_rgba(0.0, r, g, b, 0.13 * boost);
    gradient.add_color_stop_rgba(1.0, r, g, b, 0.02 * boost);
    let _ = cr.set_source(&gradient);
    let _ = cr.paint();
    let _ = cr.restore();
}

fn draw_selected_band(cr: &Context, plot: Rect, model: &PlotModel) {
    let index = model.content().selected_index;
    let Some(band) = model.content().bands.get(index) else {
        return;
    };
    let points = model.curve_points(std::slice::from_ref(band), plot, 160);
    let zero = plot.min_y() + plot.height / 2.0;
    cr.move_to(plot.min_x(), zero);
    for point in &points {
        cr.line_to(point.x, point.y);
    }
    cr.line_to(plot.max_x(), zero);
    cr.close_path();
    source(cr, band_color(index), 0.2);
    let _ = cr.fill();
}

fn draw_curve(cr: &Context, plot: Rect, model: &PlotModel, style: &Style, preview: Option<&[Point]>) {
    let bands = if style.is_enabled { model.resolved_bands().to_vec() } else { Vec::new() };
    let kept = model.curve_points(&bands, plot, 160);
    match preview {
        Some(points) => {
            draw_reference_curve(cr, &kept, style);
            draw_hero_curve(cr, plot, points, style, false);
        }
        None => draw_hero_curve(cr, plot, &kept, style, style.is_comparing && style.is_enabled),
    }
}

/// The curve in force while another is being auditioned: a thin dashed line
/// the previewed curve can be read against.
fn draw_reference_curve(cr: &Context, points: &[Point], style: &Style) {
    cr.set_line_cap(cairo::LineCap::Round);
    cr.set_line_join(cairo::LineJoin::Round);
    cr.set_line_width(1.6);
    cr.set_dash(&[6.0, 5.0], 0.0);
    source(cr, style.ink, 0.42);
    for (index, point) in points.iter().enumerate() {
        if index == 0 {
            cr.move_to(point.x, point.y);
        } else {
            cr.line_to(point.x, point.y);
        }
    }
    let _ = cr.stroke();
    cr.set_dash(&[], 0.0);
}

fn draw_hero_curve(cr: &Context, plot: Rect, points: &[Point], style: &Style, comparing: bool) {
    let zero = plot.min_y() + plot.height / 2.0;

    if comparing {
        source(cr, style.ink, 0.5);
        cr.set_line_width(1.5);
        cr.set_dash(&[5.0, 5.0], 0.0);
        cr.move_to(plot.min_x(), zero);
        cr.line_to(plot.max_x(), zero);
        let _ = cr.stroke();
        cr.set_dash(&[], 0.0);
    }

    for (above, color) in [(true, style.accent), (false, CUT)] {
        cr.move_to(plot.min_x(), zero);
        for point in points {
            cr.line_to(point.x, if above { point.y.min(zero) } else { point.y.max(zero) });
        }
        cr.line_to(plot.max_x(), zero);
        cr.close_path();
        let alpha = if comparing {
            0.05
        } else if above {
            0.22
        } else {
            0.15
        };
        source(cr, color, alpha);
        let _ = cr.fill();
    }

    let trace = |cr: &Context| {
        for (index, point) in points.iter().enumerate() {
            if index == 0 {
                cr.move_to(point.x, point.y);
            } else {
                cr.line_to(point.x, point.y);
            }
        }
    };
    cr.set_line_cap(cairo::LineCap::Round);
    cr.set_line_join(cairo::LineJoin::Round);
    let glow = if comparing { 0.1 } else { 0.7 };
    for (width, share) in [(15.0, 0.07), (11.0, 0.12), (7.5, 0.2)] {
        source(cr, style.accent, glow * share * 1.4);
        cr.set_line_width(width);
        trace(cr);
        let _ = cr.stroke();
    }
    source(cr, style.accent, if comparing { 0.2 } else { 0.85 });
    cr.set_line_width(4.0);
    trace(cr);
    let _ = cr.stroke();
    source(cr, style.ink, if comparing { 0.35 } else { 1.0 });
    cr.set_line_width(2.4);
    trace(cr);
    let _ = cr.stroke();
}

fn draw_active_column(cr: &Context, plot: Rect, model: &PlotModel, style: &Style) {
    let index = model.content().selected_index;
    if index >= GraphicSolver::CENTRES.len() {
        return;
    }
    let x = plot.min_x() + EqualizerPlot::x_for_frequency(GraphicSolver::CENTRES[index], plot.width);
    let width = plot.width * 0.1;
    let _ = cr.save();
    rounded_rectangle(cr, x - width / 2.0, plot.min_y(), width, plot.height, 10.0 * style.scale);
    cr.clip();
    let (r, g, b) = style.accent;
    let gradient = LinearGradient::new(0.0, plot.min_y(), 0.0, plot.max_y());
    gradient.add_color_stop_rgba(0.0, r, g, b, 0.0);
    gradient.add_color_stop_rgba(0.5, r, g, b, if model.is_dragging { 0.2 } else { 0.11 });
    gradient.add_color_stop_rgba(1.0, r, g, b, 0.0);
    let _ = cr.set_source(&gradient);
    let _ = cr.paint();
    let _ = cr.restore();
}

fn glow(cr: &Context, x: f64, y: f64, radius: f64, color: Rgb, alpha: f64) {
    let (r, g, b) = color;
    let gradient = RadialGradient::new(x, y, radius * 0.3, x, y, radius);
    gradient.add_color_stop_rgba(0.0, r, g, b, alpha);
    gradient.add_color_stop_rgba(1.0, r, g, b, 0.0);
    let _ = cr.set_source(&gradient);
    disc(cr, x, y, radius);
    let _ = cr.fill();
}

fn draw_nodes(cr: &Context, plot: Rect, model: &PlotModel, style: &Style, hover: Option<usize>) {
    let k = style.scale;
    for index in 0..model.node_count() {
        let is_selected = index == model.content().selected_index;
        let is_hovered = hover == Some(index);
        let center = model.node_position(index, plot);
        match model.content().mode {
            PlotMode::Simple => {
                let radius = (if is_selected { 11.0 } else { 5.5 }) * k;
                if is_selected {
                    source(cr, style.accent, 0.34);
                    disc(cr, center.x, center.y, radius + 6.0 * k);
                    let _ = cr.fill();
                    glow(cr, center.x, center.y, radius + 16.0 * k, style.accent, 0.5);
                } else if is_hovered {
                    source(cr, style.ink, 0.2);
                    disc(cr, center.x, center.y, radius + 5.0 * k);
                    let _ = cr.fill();
                }
                let fill = if style.is_dark { (1.0, 1.0, 1.0) } else { (0.98, 0.98, 1.0) };
                source(cr, fill, 1.0);
                disc(cr, center.x, center.y, radius);
                let _ = cr.fill_preserve();
                if !style.is_dark {
                    source(cr, (0.1, 0.1, 0.14), 0.5);
                    cr.set_line_width(1.0);
                    let _ = cr.stroke();
                } else {
                    cr.new_path();
                }
            }
            PlotMode::Advanced => {
                let color = band_color(index);
                let radius = (if is_selected { 12.0 } else { 8.0 }) * k;
                if is_selected {
                    glow(cr, center.x, center.y, radius + 14.0 * k, color, 0.55);
                    source(cr, style.ink, 0.9);
                    cr.set_line_width(3.0);
                    disc(cr, center.x, center.y, radius + 1.5 * k);
                    let _ = cr.stroke();
                } else if is_hovered {
                    source(cr, style.ink, 0.25);
                    disc(cr, center.x, center.y, radius + 5.0 * k);
                    let _ = cr.fill();
                }
                source(cr, color, 1.0);
                disc(cr, center.x, center.y, radius);
                let _ = cr.fill();
                if is_selected {
                    draw_text(
                        cr,
                        &format!("{}", index + 1),
                        center.x,
                        center.y,
                        Anchor::Center,
                        11.0 * k,
                        true,
                        (0.1, 0.07, 0.15),
                        1.0,
                    );
                }
            }
        }
    }
}

/// The text the value bubble shows for the band being dragged.
pub fn bubble_text(model: &PlotModel, index: usize) -> Option<String> {
    match model.content().mode {
        PlotMode::Simple => model
            .display_targets()
            .get(index)
            .map(|value| format!("{} dB", copy::decibels(*value))),
        PlotMode::Advanced => {
            let band = model.content().bands.get(index)?;
            Some(if band.filter_type.has_gain() {
                format!("{}  {} dB", copy::hertz(band.frequency), copy::decibels(band.gain))
            } else {
                copy::hertz(band.frequency)
            })
        }
    }
}

fn draw_bubble(cr: &Context, frame: &PlotFrame) {
    let PlotFrame { plot, model, style, .. } = *frame;
    let k = style.scale;
    let index = model.content().selected_index;
    if !style.is_enabled || index >= model.node_count() {
        return;
    }
    let Some(text) = bubble_text(model, index) else {
        return;
    };
    let width = text_width(cr, &text, 13.0 * k, true) + 22.0 * k;
    let center = model.node_position(index, plot);
    let x = (center.x - width / 2.0).max(4.0).min(frame.width - width - 4.0);
    let above = center.y - 48.0 * k;
    let y = if above < plot.min_y() - 6.0 * k { center.y + 24.0 * k } else { above };
    let height = 28.0 * k;
    rounded_rectangle(cr, x, y, width, height, 14.0 * k);
    source(cr, (0.16, 0.16, 0.16), 0.94);
    let _ = cr.fill();
    rounded_rectangle(cr, x + 0.5, y + 0.5, width - 1.0, height - 1.0, 14.0 * k);
    source(cr, (1.0, 1.0, 1.0), 0.18);
    cr.set_line_width(1.0);
    let _ = cr.stroke();
    draw_text(cr, &text, x + width / 2.0, y + height / 2.0, Anchor::Center, 13.0 * k, true, (1.0, 1.0, 1.0), 1.0);
}

fn draw_focus_ring(cr: &Context, plot: Rect, model: &PlotModel, style: &Style) {
    let index = model.content().selected_index;
    if index >= model.node_count() {
        return;
    }
    let center = model.node_position(index, plot);
    let k = style.scale;
    rounded_rectangle(cr, center.x - 18.0 * k, plot.min_y() - 4.0 * k, 36.0 * k, plot.height + 8.0 * k, 10.0 * k);
    source(cr, style.accent, 0.9);
    cr.set_line_width(2.0);
    let _ = cr.stroke();
}

/// The points of a small curve picture: `decibels` spread across `width`, the
/// zero line in the middle of `height`, anything past `range` held at the edge.
pub fn thumbnail_points(decibels: &[f64], width: f64, height: f64, range: f64) -> Vec<(f64, f64)> {
    if decibels.len() < 2 {
        return Vec::new();
    }
    let last = (decibels.len() - 1) as f64;
    decibels
        .iter()
        .enumerate()
        .map(|(index, value)| {
            let clamped = value.max(-range).min(range);
            (width * index as f64 / last, height / 2.0 - clamped / range * height / 2.0)
        })
        .collect()
}

/// A small picture of a curve: a preset row's thumbnail, or with `with_grid`
/// the larger preview the import sheet shows.
pub fn draw_thumbnail(
    cr: &Context,
    width: f64,
    height: f64,
    decibels: &[f64],
    color: Rgb,
    alpha: f64,
    with_grid: bool,
    ink: Rgb,
) {
    let (inset_x, inset_y, range, line) = if with_grid { (0.0, 8.0, 12.0, 2.2) } else { (1.0, 2.0, 9.0, 1.8) };
    if with_grid {
        rounded_rectangle(cr, 0.0, 0.0, width, height, 12.0);
        source(cr, ink, 0.06);
        let _ = cr.fill();
        source(cr, ink, 0.16);
        cr.set_line_width(1.0);
        cr.move_to(0.0, (height / 2.0).round() + 0.5);
        cr.line_to(width, (height / 2.0).round() + 0.5);
        let _ = cr.stroke();
    }
    let points = thumbnail_points(decibels, width - inset_x * 2.0, height - inset_y * 2.0, range);
    if points.is_empty() {
        return;
    }
    cr.set_line_cap(cairo::LineCap::Round);
    cr.set_line_join(cairo::LineJoin::Round);
    cr.set_line_width(line);
    source(cr, color, alpha);
    for (index, (x, y)) in points.iter().enumerate() {
        if index == 0 {
            cr.move_to(inset_x + x, inset_y + y);
        } else {
            cr.line_to(inset_x + x, inset_y + y);
        }
    }
    let _ = cr.stroke();
}

/// The colour of a level meter at `decibels` below full scale.
pub fn meter_color(decibels: f32) -> Rgb {
    if decibels > -1.0 {
        DANGER
    } else if decibels > -3.0 {
        CAUTION
    } else {
        LOSSLESS
    }
}

/// A status colour as text on the surface in use: the bright tones read on
/// the dark surface and are deepened on the light one.
pub fn text_tone(color: Rgb, is_dark: bool) -> Rgb {
    if is_dark {
        color
    } else {
        (color.0 * 0.6, color.1 * 0.6, color.2 * 0.6)
    }
}

/// How full a meter bar is for a peak of `decibels`: empty at -30 dB, full at 0.
pub fn meter_fraction(decibels: f32) -> f64 {
    (((decibels + 30.0) / 30.0) as f64).clamp(0.0, 1.0)
}

/// A peak as a decibel figure; silence reads as -60.
pub fn peak_decibels(peak: f32) -> f32 {
    if peak > 0.000_03 {
        20.0 * peak.log10()
    } else {
        -60.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_flat_curve_sits_on_the_middle_line() {
        let points = thumbnail_points(&[0.0; 5], 40.0, 20.0, 9.0);
        assert_eq!(points.len(), 5);
        assert!(points.iter().all(|(_, y)| (*y - 10.0).abs() < 1e-9));
        assert_eq!(points[0].0, 0.0);
        assert_eq!(points[4].0, 40.0);
    }

    #[test]
    fn a_boost_rises_and_the_range_clamps_at_the_edge() {
        let points = thumbnail_points(&[0.0, 4.5, 30.0, -30.0], 30.0, 20.0, 9.0);
        assert!(points[1].1 < points[0].1);
        assert!((points[2].1 - 0.0).abs() < 1e-9);
        assert!((points[3].1 - 20.0).abs() < 1e-9);
    }

    #[test]
    fn a_single_point_draws_nothing() {
        assert!(thumbnail_points(&[3.0], 10.0, 10.0, 9.0).is_empty());
        assert!(thumbnail_points(&[], 10.0, 10.0, 9.0).is_empty());
    }

    #[test]
    fn the_meter_reads_peaks_the_way_the_mac_does() {
        assert_eq!(peak_decibels(0.0), -60.0);
        assert!((peak_decibels(1.0)).abs() < 1e-6);
        assert_eq!(meter_fraction(-60.0), 0.0);
        assert_eq!(meter_fraction(0.0), 1.0);
        assert!((meter_fraction(-15.0) - 0.5).abs() < 1e-9);
        assert_eq!(meter_color(-0.5), DANGER);
        assert_eq!(meter_color(-2.0), CAUTION);
        assert_eq!(meter_color(-12.0), LOSSLESS);
    }

    #[test]
    fn status_colours_deepen_on_a_light_surface() {
        assert_eq!(text_tone(LOSSLESS, true), LOSSLESS);
        let deep = text_tone(LOSSLESS, false);
        assert!(deep.0 < LOSSLESS.0 && deep.1 < LOSSLESS.1 && deep.2 < LOSSLESS.2);
    }

    #[test]
    fn band_colours_wrap_around_the_palette() {
        assert_eq!(band_color(0), band_color(10));
        assert_eq!(band_color_css(0), "#ff7a8f");
    }
}
