/// A channel value at or under this counts as black. Bars decode to 0, and
/// compression noise along their edge stays well below it.
const BLACK: u8 = 24;
/// A bar is flat as well as dark: its average stays under this, where the
/// shadows of a dark stage, however deep, carry texture.
const FLAT_BLACK: f64 = 6.0;
/// The picture inside the bars must reach this brightness somewhere, or the
/// frame is too dark to tell a bar from a dark scene.
const BRIGHT_ENOUGH: u8 = 56;
/// A strip narrower than this share of the frame is an encoding edge, not a
/// bar.
const MIN_BAR: f64 = 0.02;
/// Bars on one axis never take more than this share of the frame.
const MAX_BARS: f64 = 0.6;
/// How far apart the two bars of a pair may be and still be a pair.
const SYMMETRY: f64 = 0.025;
/// How close a measured shape must come to a standard one to be taken as it.
const SNAP: f64 = 0.04;
/// The shapes pictures are made in, which a measured crop snaps to.
const STANDARD_ASPECTS: [f64; 9] = [
    1.0,
    4.0 / 3.0,
    3.0 / 2.0,
    16.0 / 9.0,
    1.85,
    2.0,
    2.2,
    2.35,
    2.39,
];
/// How dark and how vivid the glow is set against the picture it comes from.
const GLOW_LEVEL: f64 = 0.62;
const GLOW_SATURATION: f64 = 1.25;
/// Box blur passes over the glow's small grid, which together approach a
/// gaussian.
const GLOW_BLUR_PASSES: usize = 3;

/// A frame read back from the screen at a small size.
pub struct Frame<'a> {
    pub pixels: &'a [u8],
    pub width: usize,
    pub height: usize,
    pub stride: usize,
    pub channels: usize,
}

impl Frame<'_> {
    fn rgb(&self, x: usize, y: usize) -> [u8; 3] {
        let at = y * self.stride + x * self.channels;
        [self.pixels[at], self.pixels[at + 1], self.pixels[at + 2]]
    }

    fn brightest(&self, x: usize, y: usize) -> u8 {
        let [r, g, b] = self.rgb(x, y);
        r.max(g).max(b)
    }

    fn is_whole(&self) -> bool {
        self.width > 0
            && self.height > 0
            && self.channels >= 3
            && self.stride >= self.width * self.channels
            && self.pixels.len() >= (self.height - 1) * self.stride + self.width * self.channels
    }
}

/// How much of the frame to trim from each side, as shares of its width and
/// height.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Crop {
    pub left: f64,
    pub top: f64,
    pub right: f64,
    pub bottom: f64,
}

impl Crop {
    pub const NONE: Crop = Crop {
        left: 0.0,
        top: 0.0,
        right: 0.0,
        bottom: 0.0,
    };

    pub fn is_none(&self) -> bool {
        self.total() < 1e-6
    }

    fn total(&self) -> f64 {
        self.left + self.top + self.right + self.bottom
    }

    /// The share of the frame's width and height the picture keeps.
    pub fn kept(&self) -> (f64, f64) {
        (
            (1.0 - self.left - self.right).max(0.01),
            (1.0 - self.top - self.bottom).max(0.01),
        )
    }

    /// The shape of what is left once the bars are gone.
    pub fn aspect(&self, frame_aspect: f64) -> f64 {
        let (width, height) = self.kept();
        frame_aspect * width / height
    }

    fn close_to(&self, other: &Crop) -> bool {
        (self.left - other.left).abs() < 0.01
            && (self.top - other.top).abs() < 0.01
            && (self.right - other.right).abs() < 0.01
            && (self.bottom - other.bottom).abs() < 0.01
    }
}

/// The black bars burnt into one frame, snapped to the standard shape they
/// frame. `None` when the frame is too dark to tell, or its dark edges frame
/// no standard shape.
pub fn measure_bars(frame: &Frame, frame_aspect: f64) -> Option<Crop> {
    if !frame.is_whole() {
        return None;
    }
    let columns: Vec<bool> = (0..frame.width)
        .map(|x| is_bar((0..frame.height).map(|y| frame.brightest(x, y))))
        .collect();
    let rows: Vec<bool> = (0..frame.height)
        .map(|y| is_bar((0..frame.width).map(|x| frame.brightest(x, y))))
        .collect();
    let leading = |bars: &[bool]| bars.iter().take_while(|bar| **bar).count();
    let trailing = |bars: &[bool]| bars.iter().rev().take_while(|bar| **bar).count();
    let (left, right) = (leading(&columns), trailing(&columns));
    let (top, bottom) = (leading(&rows), trailing(&rows));
    if left >= frame.width || top >= frame.height {
        return None;
    }
    let inner = (top..frame.height - bottom)
        .flat_map(|y| (left..frame.width - right).map(move |x| (x, y)))
        .map(|(x, y)| frame.brightest(x, y))
        .max()
        .unwrap_or(0);
    if inner < BRIGHT_ENOUGH {
        return None;
    }
    let pair = |near: usize, far: usize, size: usize| -> Option<f64> {
        let (near, far) = (near as f64 / size as f64, far as f64 / size as f64);
        if near + far > MAX_BARS {
            return None;
        }
        if near < MIN_BAR && far < MIN_BAR {
            return Some(0.0);
        }
        if (near - far).abs() > SYMMETRY {
            return Some(0.0);
        }
        Some((near + far) / 2.0)
    };
    let horizontal = pair(left, right, frame.width)?;
    let vertical = pair(top, bottom, frame.height)?;
    snap(
        Crop {
            left: horizontal,
            right: horizontal,
            top: vertical,
            bottom: vertical,
        },
        frame_aspect,
    )
}

/// Whether one row or column of the frame is bar: never above black, and
/// flat on average.
fn is_bar(values: impl Iterator<Item = u8>) -> bool {
    let (mut count, mut sum) = (0usize, 0usize);
    for value in values {
        if value > BLACK {
            return false;
        }
        count += 1;
        sum += value as usize;
    }
    count > 0 && (sum as f64 / count as f64) <= FLAT_BLACK
}

/// Pillarbox or letterbox bars measured on a small frame are a pixel or two
/// out; the picture inside them is almost always a standard shape, so a
/// measurement close to one is taken as exactly it. One close to none is a
/// dark stage either side of the subject, not bars, and says nothing.
fn snap(crop: Crop, frame_aspect: f64) -> Option<Crop> {
    if crop.is_none() {
        return Some(Crop::NONE);
    }
    let nearest = |aspect: f64| {
        STANDARD_ASPECTS
            .into_iter()
            .min_by(|a, b| {
                (a / aspect - 1.0)
                    .abs()
                    .total_cmp(&(b / aspect - 1.0).abs())
            })
            .filter(|standard| (standard / aspect - 1.0).abs() <= SNAP)
    };
    let pillarbox = crop.left > 0.0 && crop.top == 0.0;
    let letterbox = crop.top > 0.0 && crop.left == 0.0;
    if pillarbox {
        let standard = nearest(crop.aspect(frame_aspect)).filter(|s| *s < frame_aspect)?;
        let side = (1.0 - standard / frame_aspect) / 2.0;
        return Some(Crop {
            left: side,
            right: side,
            ..Crop::NONE
        });
    }
    if letterbox {
        let standard = nearest(crop.aspect(frame_aspect)).filter(|s| *s > frame_aspect)?;
        let side = (1.0 - frame_aspect / standard) / 2.0;
        return Some(Crop {
            top: side,
            bottom: side,
            ..Crop::NONE
        });
    }
    None
}

/// Settles on a crop only once several looks agree, so a dark scene with a
/// black stage either side never crops a picture, and a crop that turns out
/// wrong is undone sooner than one is applied.
#[derive(Clone, Copy, Debug, Default)]
pub struct CropTracker {
    candidate: Option<Crop>,
    agreeing: u32,
    applied: Crop,
}

impl CropTracker {
    const TO_CROP: u32 = 3;
    const TO_UNCROP: u32 = 2;

    /// Starts from a crop already settled for this video.
    pub fn settled(applied: Crop) -> Self {
        Self {
            applied,
            ..Self::default()
        }
    }

    pub fn applied(&self) -> Crop {
        self.applied
    }

    /// Takes one look, and says whether the applied crop changed.
    pub fn observe(&mut self, seen: Option<Crop>) -> bool {
        let Some(seen) = seen else {
            return false;
        };
        if seen.close_to(&self.applied) {
            self.candidate = None;
            self.agreeing = 0;
            return false;
        }
        if self
            .candidate
            .is_some_and(|candidate| candidate.close_to(&seen))
        {
            self.agreeing += 1;
        } else {
            self.candidate = Some(seen);
            self.agreeing = 1;
        }
        let needed = if seen.total() < self.applied.total() {
            Self::TO_UNCROP
        } else {
            Self::TO_CROP
        };
        if self.agreeing < needed {
            return false;
        }
        self.applied = seen;
        self.candidate = None;
        self.agreeing = 0;
        true
    }
}

/// The glow's colours: the picture inside `crop` averaged down to a `width` by
/// `height` grid, blurred, darkened and given back a little of the saturation
/// averaging takes away. Opaque RGBA rows.
pub fn glow(frame: &Frame, crop: Crop, width: usize, height: usize) -> Vec<u8> {
    let mut grid = vec![[0.0f64; 3]; width * height];
    if frame.is_whole() && width > 0 && height > 0 {
        let x0 = crop.left * frame.width as f64;
        let y0 = crop.top * frame.height as f64;
        let (kept_width, kept_height) = crop.kept();
        let cell_width = kept_width * frame.width as f64 / width as f64;
        let cell_height = kept_height * frame.height as f64 / height as f64;
        for gy in 0..height {
            for gx in 0..width {
                let from_x = (x0 + gx as f64 * cell_width).floor() as usize;
                let to_x = ((x0 + (gx + 1) as f64 * cell_width).ceil() as usize)
                    .clamp(from_x + 1, frame.width);
                let from_y = (y0 + gy as f64 * cell_height).floor() as usize;
                let to_y = ((y0 + (gy + 1) as f64 * cell_height).ceil() as usize)
                    .clamp(from_y + 1, frame.height);
                let mut sum = [0.0f64; 3];
                let mut count = 0.0;
                for y in from_y.min(frame.height - 1)..to_y {
                    for x in from_x.min(frame.width - 1)..to_x {
                        let [r, g, b] = frame.rgb(x, y);
                        sum[0] += r as f64;
                        sum[1] += g as f64;
                        sum[2] += b as f64;
                        count += 1.0;
                    }
                }
                if count > 0.0 {
                    grid[gy * width + gx] = [sum[0] / count, sum[1] / count, sum[2] / count];
                }
            }
        }
        for _ in 0..GLOW_BLUR_PASSES {
            grid = box_blur(&grid, width, height);
        }
    }
    grid.iter()
        .flat_map(|&[r, g, b]| {
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
            let tone = |channel: f64| {
                ((luma + (channel - luma) * GLOW_SATURATION) * GLOW_LEVEL)
                    .round()
                    .clamp(0.0, 255.0) as u8
            };
            [tone(r), tone(g), tone(b), 255]
        })
        .collect()
}

/// One pass of a 3×3 box blur, edges clamped.
fn box_blur(grid: &[[f64; 3]], width: usize, height: usize) -> Vec<[f64; 3]> {
    let mut out = vec![[0.0f64; 3]; grid.len()];
    for y in 0..height {
        for x in 0..width {
            let mut sum = [0.0f64; 3];
            for dy in [-1i64, 0, 1] {
                for dx in [-1i64, 0, 1] {
                    let sx = (x as i64 + dx).clamp(0, width as i64 - 1) as usize;
                    let sy = (y as i64 + dy).clamp(0, height as i64 - 1) as usize;
                    let cell = grid[sy * width + sx];
                    sum[0] += cell[0];
                    sum[1] += cell[1];
                    sum[2] += cell[2];
                }
            }
            out[y * width + x] = [sum[0] / 9.0, sum[1] / 9.0, sum[2] / 9.0];
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const WIDE: f64 = 16.0 / 9.0;

    /// A 128×72 frame of mid-grey picture inside black bars of the given
    /// widths in pixels.
    fn framed(left: usize, right: usize, top: usize, bottom: usize, level: u8) -> Vec<u8> {
        let (width, height) = (128, 72);
        let mut pixels = vec![0u8; width * height * 3];
        for y in top..height - bottom {
            for x in left..width - right {
                let at = (y * width + x) * 3;
                let shade = level.saturating_sub(((x + y) % 7) as u8 * 3);
                pixels[at..at + 3].copy_from_slice(&[shade, shade / 2, shade / 3]);
            }
        }
        pixels
    }

    fn frame(pixels: &[u8]) -> Frame<'_> {
        Frame {
            pixels,
            width: 128,
            height: 72,
            stride: 128 * 3,
            channels: 3,
        }
    }

    #[test]
    fn a_four_by_three_picture_in_a_wide_frame_is_cropped_to_exactly_four_by_three() {
        let pixels = framed(16, 16, 0, 0, 200);
        let crop = measure_bars(&frame(&pixels), WIDE).unwrap();
        assert!((crop.aspect(WIDE) - 4.0 / 3.0).abs() < 1e-9);
        assert_eq!(crop.left, crop.right);
        assert_eq!(crop.top, 0.0);
    }

    #[test]
    fn a_bar_a_pixel_off_still_snaps_to_the_standard_shape() {
        let pixels = framed(15, 17, 0, 0, 200);
        let crop = measure_bars(&frame(&pixels), WIDE).unwrap();
        assert!((crop.aspect(WIDE) - 4.0 / 3.0).abs() < 1e-9);
    }

    #[test]
    fn a_scope_picture_letterboxed_in_a_wide_frame_loses_its_bars() {
        let pixels = framed(0, 0, 9, 9, 200);
        let crop = measure_bars(&frame(&pixels), WIDE).unwrap();
        assert!(
            (crop.aspect(WIDE) - 2.35).abs() < 0.05,
            "{}",
            crop.aspect(WIDE)
        );
        assert_eq!(crop.left, 0.0);
    }

    #[test]
    fn a_full_frame_picture_is_not_cropped() {
        let pixels = framed(0, 0, 0, 0, 200);
        assert_eq!(measure_bars(&frame(&pixels), WIDE), Some(Crop::NONE));
    }

    #[test]
    fn a_dark_frame_says_nothing_about_bars() {
        let pixels = framed(16, 16, 0, 0, 40);
        assert_eq!(measure_bars(&frame(&pixels), WIDE), None);
        let black = vec![0u8; 128 * 72 * 3];
        assert_eq!(measure_bars(&frame(&black), WIDE), None);
    }

    #[test]
    fn a_dark_strip_down_one_side_only_is_not_a_bar() {
        let pixels = framed(20, 0, 0, 0, 200);
        assert_eq!(measure_bars(&frame(&pixels), WIDE), Some(Crop::NONE));
    }

    #[test]
    fn a_dark_stage_either_side_of_a_four_by_three_picture_is_not_cropped_into() {
        let pixels = framed(37, 37, 0, 0, 200);
        assert_eq!(measure_bars(&frame(&pixels), WIDE), None);
    }

    #[test]
    fn dim_textured_sides_are_picture_not_bars() {
        let mut pixels = framed(16, 16, 0, 0, 200);
        for y in 0..72 {
            for x in (0..16).chain(112..128) {
                let at = (y * 128 + x) * 3;
                let shade = 6 + ((x * 7 + y * 13) % 14) as u8;
                pixels[at..at + 3].copy_from_slice(&[shade, shade, shade]);
            }
        }
        assert_eq!(measure_bars(&frame(&pixels), WIDE), Some(Crop::NONE));
    }

    #[test]
    fn a_crop_is_applied_only_once_three_looks_agree() {
        let pillarbox = Crop {
            left: 0.125,
            right: 0.125,
            ..Crop::NONE
        };
        let mut tracker = CropTracker::default();
        assert!(!tracker.observe(Some(pillarbox)));
        assert!(!tracker.observe(None));
        assert!(!tracker.observe(Some(pillarbox)));
        assert!(tracker.observe(Some(pillarbox)));
        assert_eq!(tracker.applied(), pillarbox);
    }

    #[test]
    fn a_disagreeing_look_starts_the_count_again() {
        let pillarbox = Crop {
            left: 0.125,
            right: 0.125,
            ..Crop::NONE
        };
        let mut tracker = CropTracker::default();
        tracker.observe(Some(pillarbox));
        tracker.observe(Some(pillarbox));
        tracker.observe(Some(Crop::NONE));
        assert!(!tracker.observe(Some(pillarbox)));
        assert_eq!(tracker.applied(), Crop::NONE);
    }

    #[test]
    fn a_wrong_crop_is_undone_after_two_looks() {
        let pillarbox = Crop {
            left: 0.125,
            right: 0.125,
            ..Crop::NONE
        };
        let mut tracker = CropTracker::settled(pillarbox);
        assert!(!tracker.observe(Some(Crop::NONE)));
        assert!(tracker.observe(Some(Crop::NONE)));
        assert!(tracker.applied().is_none());
    }

    #[test]
    fn the_glow_ignores_the_bars_and_is_opaque() {
        let pixels = framed(16, 16, 0, 0, 200);
        let crop = measure_bars(&frame(&pixels), WIDE).unwrap();
        let glow = glow(&frame(&pixels), crop, 8, 4);
        assert_eq!(glow.len(), 8 * 4 * 4);
        assert!(glow.chunks(4).all(|pixel| pixel[3] == 255));
        assert!(glow.chunks(4).all(|pixel| pixel[0] > 60), "{glow:?}");
    }

    #[test]
    fn a_short_buffer_is_refused_rather_than_read_past() {
        let pixels = vec![0u8; 10];
        assert_eq!(measure_bars(&frame(&pixels), WIDE), None);
        assert_eq!(glow(&frame(&pixels), Crop::NONE, 2, 2).len(), 16);
    }
}
