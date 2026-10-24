//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Library/ArtworkFraming.swift`.
//!
//! How a person has framed a cover: which part of a source image shows through
//! a square window. The image is measured in source pixels, the window in
//! whatever points the toolkit lays out, and `zoom` is window points per source
//! pixel. Anchors and deltas are window points from the window's top-left.

pub const MAXIMUM_ZOOM_MULTIPLE: f64 = 5.0;
pub const DOUBLE_CLICK_MULTIPLE: f64 = 2.5;
pub const ZOOM_CEILING_FLOOR: f64 = 1.0;

/// A cover showing fewer source pixels than this will look soft on a large
/// display, which the editor says out loud.
pub const SOFT_BELOW_PIXELS: f64 = 500.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ArtworkFraming {
    pub image_width: f64,
    pub image_height: f64,
    frame_side: f64,
    zoom: f64,
    center_x: f64,
    center_y: f64,
}

impl ArtworkFraming {
    /// Framing a freshly loaded image: filled, centred. None when the image or
    /// the window has no usable size.
    pub fn new(image_width: f64, image_height: f64, frame_side: f64) -> Option<Self> {
        let usable = |value: f64| value.is_finite() && value > 0.0;
        if !(usable(image_width) && usable(image_height) && usable(frame_side)) {
            return None;
        }
        Some(Self {
            image_width,
            image_height,
            frame_side,
            zoom: frame_side / image_width.min(image_height),
            center_x: image_width / 2.0,
            center_y: image_height / 2.0,
        })
    }

    pub fn frame_side(&self) -> f64 {
        self.frame_side
    }

    pub fn zoom(&self) -> f64 {
        self.zoom
    }

    pub fn center_x(&self) -> f64 {
        self.center_x
    }

    pub fn center_y(&self) -> f64 {
        self.center_y
    }

    pub fn fill_zoom(&self) -> f64 {
        self.frame_side / self.image_width.min(self.image_height)
    }

    pub fn max_zoom(&self) -> f64 {
        (self.fill_zoom() * MAXIMUM_ZOOM_MULTIPLE)
            .max(ZOOM_CEILING_FLOOR)
            .max(self.fill_zoom())
    }

    pub fn is_at_fill(&self) -> bool {
        self.zoom <= self.fill_zoom() * 1.01
    }

    pub fn is_soft(&self) -> bool {
        self.visible_side() < SOFT_BELOW_PIXELS
    }

    /// Side of the source square currently showing, in source pixels.
    pub fn visible_side(&self) -> f64 {
        self.frame_side / self.zoom
    }

    pub fn visible_x(&self) -> f64 {
        self.center_x - self.visible_side() / 2.0
    }

    pub fn visible_y(&self) -> f64 {
        self.center_y - self.visible_side() / 2.0
    }

    /// Where the zoom sits between filled (0) and fully in (1) on a log scale.
    pub fn zoom_fraction(&self) -> f64 {
        let span = (self.max_zoom() / self.fill_zoom()).ln();
        if span <= 0.0 {
            return 0.0;
        }
        ((self.zoom / self.fill_zoom()).ln() / span).clamp(0.0, 1.0)
    }

    /// Side in pixels of the square to render for the current framing, never
    /// more than `limit` and never more than the source can supply.
    pub fn output_pixels(&self, limit: u32) -> u32 {
        let visible = self.visible_side().round().max(0.0) as u32;
        visible.min(limit).max(1)
    }

    /// The same framing after the window changed size: what showed stays
    /// showing, scaled to the new window.
    pub fn resized(&self, frame_side: f64) -> Self {
        if !frame_side.is_finite() || frame_side <= 0.0 || frame_side == self.frame_side {
            return *self;
        }
        let ratio = self.zoom / self.fill_zoom();
        let mut next = *self;
        next.frame_side = frame_side;
        next.zoom = (next.fill_zoom() * ratio)
            .max(next.fill_zoom())
            .min(next.max_zoom());
        next.clamp_center();
        next
    }

    /// The content following a drag of (`dx`, `dy`) window points.
    pub fn panned(&self, dx: f64, dy: f64) -> Self {
        let mut next = *self;
        next.center_x -= dx / self.zoom;
        next.center_y -= dy / self.zoom;
        next.clamp_center();
        next
    }

    /// Zooms to `target`, keeping the source point under the anchor where it
    /// is. The anchor defaults to the window's centre.
    pub fn zoomed(&self, target: f64, anchor: Option<(f64, f64)>) -> Self {
        if !target.is_finite() || target <= 0.0 {
            return *self;
        }
        let half = self.frame_side / 2.0;
        let (ax, ay) = anchor.map_or((0.0, 0.0), |(x, y)| (x - half, y - half));
        let point_x = self.center_x + ax / self.zoom;
        let point_y = self.center_y + ay / self.zoom;
        let mut next = *self;
        next.zoom = target.max(self.fill_zoom()).min(self.max_zoom());
        next.center_x = point_x - ax / next.zoom;
        next.center_y = point_y - ay / next.zoom;
        next.clamp_center();
        next
    }

    pub fn zoomed_by(&self, factor: f64, anchor: Option<(f64, f64)>) -> Self {
        if !factor.is_finite() || factor <= 0.0 {
            return *self;
        }
        self.zoomed(self.zoom * factor, anchor)
    }

    pub fn zoomed_to_fraction(&self, fraction: f64) -> Self {
        let fraction = if fraction.is_finite() { fraction } else { 0.0 }.clamp(0.0, 1.0);
        let span = (self.max_zoom() / self.fill_zoom()).ln();
        self.zoomed(self.fill_zoom() * (fraction * span).exp(), None)
    }

    /// Double click: in from the filled state around the pointer, back out to
    /// filled otherwise.
    pub fn toggled(&self, anchor_x: f64, anchor_y: f64) -> Self {
        let anchor = Some((anchor_x, anchor_y));
        if self.is_at_fill() {
            let target = self
                .max_zoom()
                .min(self.fill_zoom() * DOUBLE_CLICK_MULTIPLE);
            return self.zoomed(target, anchor);
        }
        self.zoomed(self.fill_zoom(), anchor)
    }

    fn clamp_center(&mut self) {
        let half = self.visible_side() / 2.0;
        self.center_x = self.center_x.max(half).min((self.image_width - half).max(half));
        self.center_y = self.center_y.max(half).min((self.image_height - half).max(half));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const EPS: f64 = 1e-9;

    fn framing(width: f64, height: f64, side: f64) -> ArtworkFraming {
        ArtworkFraming::new(width, height, side).expect("usable framing")
    }

    #[test]
    fn f1_fresh_framing_fills_and_centres() {
        let f = framing(3000.0, 2000.0, 400.0);
        assert!((f.zoom() - 0.2).abs() < EPS);
        assert!((f.fill_zoom() - 0.2).abs() < EPS);
        assert!((f.visible_side() - 2000.0).abs() < EPS);
        assert!((f.center_x() - 1500.0).abs() < EPS);
        assert!((f.center_y() - 1000.0).abs() < EPS);
        assert!(f.is_at_fill());
    }

    #[test]
    fn f2_unusable_sizes_yield_no_framing() {
        assert!(ArtworkFraming::new(0.0, 100.0, 400.0).is_none());
        assert!(ArtworkFraming::new(100.0, 100.0, 0.0).is_none());
        assert!(ArtworkFraming::new(f64::NAN, 100.0, 400.0).is_none());
    }

    #[test]
    fn f3_maximum_zoom_is_five_times_fill_with_a_one_pixel_floor() {
        assert!((framing(3000.0, 3000.0, 400.0).max_zoom() - 1.0).abs() < EPS);
        assert!((framing(1000.0, 1000.0, 400.0).max_zoom() - 2.0).abs() < EPS);
        assert!((framing(100.0, 100.0, 400.0).max_zoom() - 20.0).abs() < EPS);
    }

    #[test]
    fn f4_pan_follows_the_drag_and_stops_at_the_image_edge() {
        let f = framing(3000.0, 2000.0, 400.0).panned(-100.0, 0.0);
        assert!((f.center_x() - 2000.0).abs() < EPS);
        assert!((f.center_y() - 1000.0).abs() < EPS);
        assert!((f.panned(-100_000.0, 0.0).center_x() - 2000.0).abs() < EPS);
        assert!((f.panned(100_000.0, 0.0).center_x() - 1000.0).abs() < EPS);
    }

    #[test]
    fn f5_the_pan_axis_of_a_square_fill_has_no_slack() {
        let f = framing(2000.0, 2000.0, 400.0).panned(300.0, -300.0);
        assert!((f.center_x() - 1000.0).abs() < EPS);
        assert!((f.center_y() - 1000.0).abs() < EPS);
    }

    #[test]
    fn f6_zoom_keeps_the_point_under_the_anchor_fixed() {
        let start = framing(3000.0, 3000.0, 400.0);
        let (ax, ay) = (100.0, 300.0);
        let before = (
            start.center_x() + (ax - 200.0) / start.zoom(),
            start.center_y() + (ay - 200.0) / start.zoom(),
        );
        let zoomed = start.zoomed(0.5, Some((ax, ay)));
        let after = (
            zoomed.center_x() + (ax - 200.0) / zoomed.zoom(),
            zoomed.center_y() + (ay - 200.0) / zoomed.zoom(),
        );
        assert!((zoomed.zoom() - 0.5).abs() < EPS);
        assert!((after.0 - before.0).abs() < 1e-6);
        assert!((after.1 - before.1).abs() < 1e-6);
    }

    #[test]
    fn f7_zoom_is_clamped_between_fill_and_maximum() {
        let f = framing(2000.0, 2000.0, 400.0);
        assert!((f.zoomed(0.0001, None).zoom() - f.fill_zoom()).abs() < EPS);
        assert!((f.zoomed(1000.0, None).zoom() - f.max_zoom()).abs() < EPS);
        assert!((f.zoomed_by(0.0, None).zoom() - f.zoom()).abs() < EPS);
    }

    #[test]
    fn f8_zoomed_to_a_corner_stays_inside_the_image() {
        let f = framing(2000.0, 2000.0, 400.0).zoomed(1.0, Some((0.0, 0.0)));
        assert!(f.visible_x() >= -EPS);
        assert!(f.visible_y() >= -EPS);
        assert!(f.visible_x() + f.visible_side() <= 2000.0 + EPS);
    }

    #[test]
    fn f9_double_click_zooms_in_then_back_out() {
        let f = framing(2000.0, 2000.0, 400.0);
        let into = f.toggled(200.0, 200.0);
        assert!((into.zoom() - f.fill_zoom() * 2.5).abs() < EPS);
        assert!(!into.is_at_fill());
        let out = into.toggled(200.0, 200.0);
        assert!((out.zoom() - f.fill_zoom()).abs() < EPS);
        assert!(out.is_at_fill());
    }

    #[test]
    fn f10_zoom_fraction_runs_logarithmically_from_zero_to_one() {
        let f = framing(2000.0, 2000.0, 400.0);
        assert!(f.zoom_fraction().abs() < EPS);
        assert!((f.zoomed_to_fraction(1.0).zoom_fraction() - 1.0).abs() < EPS);
        let half = f.zoomed_to_fraction(0.5);
        let expected = f.fill_zoom() * (f.max_zoom() / f.fill_zoom()).powf(0.5);
        assert!((half.zoom() - expected).abs() < EPS);
        assert!((half.zoom_fraction() - 0.5).abs() < EPS);
    }

    #[test]
    fn f11_resizing_keeps_what_showed() {
        let zoomed = framing(2000.0, 2000.0, 400.0).zoomed(0.6, Some((50.0, 50.0)));
        let resized = zoomed.resized(200.0);
        assert!((resized.visible_side() - zoomed.visible_side()).abs() < EPS);
        assert!((resized.center_x() - zoomed.center_x()).abs() < EPS);
        assert!((resized.center_y() - zoomed.center_y()).abs() < EPS);
    }

    #[test]
    fn f12_output_is_capped_at_the_limit_and_by_the_source() {
        let f = framing(3000.0, 3000.0, 400.0);
        assert_eq!(f.output_pixels(1600), 1600);
        assert_eq!(framing(900.0, 900.0, 400.0).output_pixels(1600), 900);
        assert_eq!(f.zoomed(1.0, None).output_pixels(1600), 400);
    }

    #[test]
    fn f13_tall_images_fill_on_their_narrow_edge() {
        let f = framing(1000.0, 4000.0, 400.0);
        assert!((f.fill_zoom() - 0.4).abs() < EPS);
        assert!((f.visible_side() - 1000.0).abs() < EPS);
        let panned = f.panned(0.0, -100_000.0);
        assert!((panned.center_y() - 3500.0).abs() < EPS);
        assert!((panned.center_x() - 500.0).abs() < EPS);
    }

    #[test]
    fn f14_a_framing_is_soft_when_fewer_than_five_hundred_pixels_show() {
        assert!(!framing(1000.0, 1000.0, 400.0).is_soft());
        assert!(framing(400.0, 400.0, 400.0).is_soft());
        assert!(framing(3000.0, 3000.0, 400.0).zoomed(1.0, None).is_soft());
        assert!(!framing(500.0, 500.0, 400.0).is_soft());
    }
}
