/// How the carousel is proportioned: the cover in the middle at full size,
/// its neighbours smaller, and a fixed gap between any two.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Flow {
    pub side: f64,
    pub neighbour_scale: f64,
    pub gap: f64,
}

/// Where one cover of the carousel is drawn.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Slot {
    pub index: usize,
    pub x: f64,
    pub y: f64,
    pub side: f64,
    pub opacity: f64,
}

const NEIGHBOUR_OPACITY: f64 = 0.62;
const SMALLEST_SIDE: f64 = 132.0;
const LARGEST_SIDE: f64 = 560.0;
const WIDTH_SHARE: f64 = 0.4;
const VERTICAL_MARGIN: f64 = 20.0;

impl Flow {
    /// The proportions for a carousel of this size: the middle cover as tall
    /// as the room allows without taking more than its share of the width.
    pub fn fitting(width: f64, height: f64) -> Flow {
        let side = (height - 2.0 * VERTICAL_MARGIN)
            .min(width * WIDTH_SHARE)
            .clamp(SMALLEST_SIDE, LARGEST_SIDE)
            .round();
        Flow {
            side,
            neighbour_scale: 0.6,
            gap: (side * 0.09).round(),
        }
    }

    fn neighbour_side(&self) -> f64 {
        self.side * self.neighbour_scale
    }

    /// The edge of a cover `distance` places from the middle.
    pub fn side_at(&self, distance: f64) -> f64 {
        self.side - (self.side - self.neighbour_side()) * distance.abs().min(1.0)
    }

    /// How far the centre of a cover `distance` places from the middle sits
    /// from the centre of the carousel. The first place covers the growing
    /// distance between the big cover and a small one; every further place is
    /// one small cover and one gap. Any two neighbours end up exactly one gap
    /// apart wherever the carousel is stopped.
    pub fn offset_at(&self, distance: f64) -> f64 {
        let first = self.side / 2.0 + self.gap + self.neighbour_side() / 2.0;
        let reach = distance.abs();
        let offset = if reach <= 1.0 {
            reach * first
        } else {
            first + (reach - 1.0) * (self.neighbour_side() + self.gap)
        };
        offset.copysign(distance)
    }

    /// The pixels one place takes away from the middle, for turning a drag
    /// into places.
    pub fn pitch(&self) -> f64 {
        self.neighbour_side() + self.gap
    }

    /// Every cover that shows at all when the carousel rests at `position`
    /// (a fractional index) in a room of `width` by `height`, nearest the
    /// middle last so it is the one on top.
    pub fn slots(&self, width: f64, height: f64, position: f64, count: usize) -> Vec<Slot> {
        if count == 0 || width <= 0.0 {
            return Vec::new();
        }
        let reach = ((width / 2.0) / self.pitch()).ceil() as i64 + 2;
        let middle = position.round() as i64;
        let mut slots: Vec<Slot> = (middle - reach..=middle + reach)
            .filter(|index| *index >= 0 && (*index as usize) < count)
            .filter_map(|index| {
                let distance = index as f64 - position;
                let side = self.side_at(distance);
                let x = width / 2.0 + self.offset_at(distance) - side / 2.0;
                if x + side <= 0.0 || x >= width {
                    return None;
                }
                Some(Slot {
                    index: index as usize,
                    x,
                    y: (height - side) / 2.0,
                    side,
                    opacity: 1.0 - (1.0 - NEIGHBOUR_OPACITY) * distance.abs().min(1.0),
                })
            })
            .collect();
        slots.sort_by(|a, b| {
            let far = |slot: &Slot| (slot.index as f64 - position).abs();
            far(b)
                .partial_cmp(&far(a))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        slots
    }
}

/// A critically damped spring: the carousel's position chasing the place it
/// was sent to, quick without overshooting.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Glide {
    pub position: f64,
    pub velocity: f64,
}

const STIFFNESS: f64 = 170.0;
const REST_DISTANCE: f64 = 0.0008;
const REST_SPEED: f64 = 0.01;

impl Glide {
    /// Moves one frame of `seconds` towards `target`. Returns false once it
    /// has arrived and come to rest, with the position set exactly on target.
    pub fn step(&mut self, target: f64, seconds: f64) -> bool {
        let damping = 2.0 * STIFFNESS.sqrt();
        let acceleration = STIFFNESS * (target - self.position) - damping * self.velocity;
        self.velocity += acceleration * seconds;
        self.position += self.velocity * seconds;
        if (target - self.position).abs() < REST_DISTANCE && self.velocity.abs() < REST_SPEED {
            self.position = target;
            self.velocity = 0.0;
            return false;
        }
        true
    }
}

/// The place a carousel of `count` covers may be sent to, kept on the shelf.
pub fn clamped(place: f64, count: usize) -> f64 {
    place.clamp(0.0, count.saturating_sub(1) as f64)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FLOW: Flow = Flow {
        side: 300.0,
        neighbour_scale: 0.6,
        gap: 24.0,
    };

    fn ordered(mut slots: Vec<Slot>) -> Vec<Slot> {
        slots.sort_by_key(|slot| slot.index);
        slots
    }

    #[test]
    fn the_middle_cover_is_full_size_and_centred() {
        let slots = ordered(FLOW.slots(1200.0, 400.0, 5.0, 20));
        let middle = slots.iter().find(|slot| slot.index == 5).unwrap();
        assert_eq!(middle.side, 300.0);
        assert_eq!(middle.x, 450.0);
        assert_eq!(middle.y, 50.0);
        assert_eq!(middle.opacity, 1.0);
        let next = slots.iter().find(|slot| slot.index == 6).unwrap();
        assert_eq!(next.side, 180.0);
        assert_eq!(next.y, 110.0);
        assert!((next.opacity - NEIGHBOUR_OPACITY).abs() < 1e-9);
    }

    #[test]
    fn neighbours_stay_one_gap_apart_wherever_it_stops() {
        for step in 0..=40 {
            let position = 7.0 + step as f64 / 40.0;
            let slots = ordered(FLOW.slots(1600.0, 400.0, position, 30));
            for pair in slots.windows(2) {
                let between = pair[1].x - (pair[0].x + pair[0].side);
                assert!(
                    (between - FLOW.gap).abs() < 1e-6,
                    "at {position}: {} and {} are {between} apart",
                    pair[0].index,
                    pair[1].index
                );
            }
        }
    }

    #[test]
    fn it_is_the_same_on_both_sides() {
        let slots = ordered(FLOW.slots(1400.0, 400.0, 10.0, 40));
        let left = slots.iter().find(|slot| slot.index == 8).unwrap();
        let right = slots.iter().find(|slot| slot.index == 12).unwrap();
        assert_eq!(left.side, right.side);
        assert!(
            ((700.0 - (left.x + left.side / 2.0)) - ((right.x + right.side / 2.0) - 700.0)).abs()
                < 1e-9
        );
    }

    #[test]
    fn only_covers_that_show_are_laid_out_and_the_nearest_comes_last() {
        let slots = FLOW.slots(1000.0, 400.0, 50.0, 800);
        assert!(
            slots.len() <= 9,
            "{} covers for a 1000 px room",
            slots.len()
        );
        assert!(slots
            .iter()
            .all(|slot| slot.x + slot.side > 0.0 && slot.x < 1000.0));
        assert_eq!(slots.last().unwrap().index, 50);
        assert!(FLOW.slots(1000.0, 400.0, 0.0, 0).is_empty());
        let start = ordered(FLOW.slots(1000.0, 400.0, 0.0, 3));
        assert_eq!(
            start.iter().map(|slot| slot.index).collect::<Vec<_>>(),
            [0, 1, 2]
        );
    }

    #[test]
    fn the_cover_fits_the_room_it_is_given() {
        assert_eq!(Flow::fitting(1600.0, 420.0).side, 380.0);
        assert_eq!(Flow::fitting(1350.0, 600.0).side, 540.0);
        assert_eq!(Flow::fitting(600.0, 420.0).side, 240.0);
        assert_eq!(Flow::fitting(300.0, 100.0).side, SMALLEST_SIDE);
        assert_eq!(Flow::fitting(4000.0, 2000.0).side, LARGEST_SIDE);
    }

    #[test]
    fn a_glide_arrives_without_overshooting_and_then_rests() {
        let mut glide = Glide::default();
        let mut frames = 0;
        let mut furthest: f64 = 0.0;
        while glide.step(3.0, 1.0 / 60.0) {
            furthest = furthest.max(glide.position);
            frames += 1;
            assert!(frames < 600, "the glide never came to rest");
        }
        assert_eq!(glide.position, 3.0);
        assert_eq!(glide.velocity, 0.0);
        assert!(furthest <= 3.0 + 1e-6, "overshot to {furthest}");
        assert!(frames < 90, "took {frames} frames to move three places");
    }

    #[test]
    fn a_place_stays_on_the_shelf() {
        assert_eq!(clamped(-2.0, 10), 0.0);
        assert_eq!(clamped(4.4, 10), 4.4);
        assert_eq!(clamped(99.0, 10), 9.0);
        assert_eq!(clamped(3.0, 0), 0.0);
    }
}
