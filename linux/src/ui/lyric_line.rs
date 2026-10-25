use flaccy_shared::lyrics::{LineProgress, Word};
use gtk::glib;
use gtk::graphene;
use gtk::gsk;
use gtk::pango;
use gtk::prelude::*;
use gtk::subclass::prelude::*;

/// How wide the soft edge of the fill is, in logical pixels.
const EDGE_SOFTNESS: f32 = 10.0;
/// How much of the line's colour the not-yet-sung part keeps while a fill is
/// running over it.
const UNSUNG_ALPHA: f32 = 0.55;
/// The narrowest a line asks for; it wraps to whatever width it is given.
const MIN_WIDTH: i32 = 24;
/// A fill edge that moved less than this many logical pixels is not redrawn.
const REDRAW_STEP: f32 = 0.5;

/// One wrapped row of a laid-out line, in widget coordinates.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VisualLine {
    pub top: f32,
    pub height: f32,
    pub left: f32,
    pub right: f32,
    pub rtl: bool,
}

/// How far the fill has got through a laid-out line.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum SungEdge {
    Nothing,
    Everything,
    At { line: usize, x: f32 },
}

/// How one wrapped row is painted.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Fill {
    Unsung,
    Sung,
    Edge(f32),
}

/// Rows before the edge are sung, rows after it are not, and the row holding
/// it is split at the edge.
pub fn fills(rows: usize, edge: SungEdge) -> Vec<Fill> {
    (0..rows)
        .map(|index| match edge {
            SungEdge::Nothing => Fill::Unsung,
            SungEdge::Everything => Fill::Sung,
            SungEdge::At { line, x } if index == line => Fill::Edge(x),
            SungEdge::At { line, .. } if index < line => Fill::Sung,
            SungEdge::At { .. } => Fill::Unsung,
        })
        .collect()
}

/// Where the fill edge sits inside a word: `fraction` of the way from where
/// the word starts to where it ends on its row.
pub fn edge_inside(start: f32, end: f32, fraction: f64) -> f32 {
    start + (end - start) * fraction.clamp(0.0, 1.0) as f32
}

/// Stands for "no wrap width": the line is laid out on one row.
const UNWRAPPED: i32 = -1;

/// The one layout a line keeps, shared by measuring and drawing. It is rebuilt
/// only when the font, the scale factor or the text direction it was built
/// under changes, and re-wrapped only when it is asked for another width.
pub struct Cached {
    font: Option<pango::FontDescription>,
    scale_factor: i32,
    direction: gtk::TextDirection,
    layout: pango::Layout,
    width: i32,
    rows: Vec<VisualLine>,
    rows_valid: bool,
    natural_width: Option<i32>,
}

mod imp {
    use super::*;
    use std::cell::{Cell, RefCell};

    #[derive(Default)]
    pub struct LyricLine {
        pub text: RefCell<String>,
        pub ranges: RefCell<Vec<(usize, usize)>>,
        pub cached: RefCell<Option<Cached>>,
        pub progress: Cell<Option<LineProgress>>,
        pub last_edge: Cell<Option<SungEdge>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for LyricLine {
        const NAME: &'static str = "FlaccyLyricLine";
        type Type = super::LyricLine;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for LyricLine {}

    impl WidgetImpl for LyricLine {
        fn request_mode(&self) -> gtk::SizeRequestMode {
            gtk::SizeRequestMode::HeightForWidth
        }

        fn measure(&self, orientation: gtk::Orientation, for_size: i32) -> (i32, i32, i32, i32) {
            let obj = self.obj();
            match orientation {
                gtk::Orientation::Horizontal => {
                    let width = obj.natural_text_width();
                    (MIN_WIDTH.min(width), width.max(MIN_WIDTH), -1, -1)
                }
                _ => {
                    let height = obj.wrapped_text_height(for_size);
                    (height, height, -1, -1)
                }
            }
        }

        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let obj = self.obj();
            let width = obj.width();
            if width <= 0 {
                return;
            }
            obj.ensure_layout(width);
            let cached = self.cached.borrow();
            let Some(cached) = cached.as_ref() else { return };
            let bright = obj.color();
            let Some(progress) = self.progress.get() else {
                snapshot.append_layout(&cached.layout, &bright);
                return;
            };
            let mut unsung = obj
                .parent()
                .map_or(bright, |parent| parent.color());
            unsung.set_alpha(unsung.alpha() * UNSUNG_ALPHA);
            let edge = obj.edge_for(cached, progress);
            for (row, fill) in cached.rows.iter().zip(fills(cached.rows.len(), edge)) {
                let bounds = graphene::Rect::new(0.0, row.top, width as f32, row.height);
                snapshot.push_clip(&bounds);
                match fill {
                    Fill::Sung => snapshot.append_layout(&cached.layout, &bright),
                    Fill::Unsung => snapshot.append_layout(&cached.layout, &unsung),
                    Fill::Edge(x) => {
                        snapshot.append_layout(&cached.layout, &unsung);
                        snapshot.push_mask(gsk::MaskMode::Alpha);
                        let (from, to) = if row.rtl {
                            (x + EDGE_SOFTNESS / 2.0, x - EDGE_SOFTNESS / 2.0)
                        } else {
                            (x - EDGE_SOFTNESS / 2.0, x + EDGE_SOFTNESS / 2.0)
                        };
                        snapshot.append_linear_gradient(
                            &bounds,
                            &graphene::Point::new(from, row.top),
                            &graphene::Point::new(to, row.top),
                            &[
                                gsk::ColorStop::new(0.0, gtk::gdk::RGBA::new(0.0, 0.0, 0.0, 1.0)),
                                gsk::ColorStop::new(1.0, gtk::gdk::RGBA::new(0.0, 0.0, 0.0, 0.0)),
                            ],
                        );
                        snapshot.pop();
                        snapshot.append_layout(&cached.layout, &bright);
                        snapshot.pop();
                    }
                }
                snapshot.pop();
            }
        }
    }
}

glib::wrapper! {
    /// One line of lyrics. It draws its own text so that, while a line with
    /// timed words is being sung, the sung part can be one colour and the rest
    /// another with a soft edge between them: the same glyphs are drawn twice
    /// through clips, never scaled or re-rendered, so the fill costs one small
    /// repaint per frame.
    pub struct LyricLine(ObjectSubclass<imp::LyricLine>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl LyricLine {
    pub fn new(text: &str, words: &[Word]) -> Self {
        let line: Self = glib::Object::new();
        let imp = line.imp();
        *imp.text.borrow_mut() = text.to_string();
        let mut offset = 0usize;
        *imp.ranges.borrow_mut() = words
            .iter()
            .map(|word| {
                let range = (offset, offset + word.text.len());
                offset = range.1;
                range
            })
            .collect();
        line.set_hexpand(true);
        line.add_css_class("lyric-text");
        line.update_property(&[gtk::accessible::Property::Label(text)]);
        line
    }

    /// Starts, moves or ends the fill. `None` draws the line plainly.
    pub fn set_progress(&self, progress: Option<LineProgress>) {
        let imp = self.imp();
        let previous = imp.progress.replace(progress);
        let Some(progress) = progress else {
            imp.last_edge.set(None);
            if previous.is_some() {
                self.queue_draw();
            }
            return;
        };
        self.ensure_layout(self.width().max(1));
        let edge = {
            let cached = imp.cached.borrow();
            cached.as_ref().map(|cached| self.edge_for(cached, progress))
        };
        let moved = match (edge, imp.last_edge.get()) {
            (Some(now), Some(before)) => !same_edge(now, before),
            _ => true,
        };
        if moved {
            imp.last_edge.set(edge);
            self.queue_draw();
        }
    }

    /// Makes the cached layout current: built under the font, scale factor and
    /// direction the widget resolves to now, and wrapped at `width`
    /// (`UNWRAPPED` for none). Nothing is rebuilt or re-wrapped when it already
    /// is.
    fn prepare_layout(&self, width: i32) {
        let imp = self.imp();
        let font = self.pango_context().font_description();
        let scale_factor = self.scale_factor();
        let direction = self.direction();
        let mut cached = imp.cached.borrow_mut();
        let current = cached.as_ref().is_some_and(|cached| {
            cached.font == font
                && cached.scale_factor == scale_factor
                && cached.direction == direction
        });
        if !current {
            let layout = self.create_pango_layout(Some(imp.text.borrow().as_str()));
            layout.set_wrap(pango::WrapMode::WordChar);
            *cached = Some(Cached {
                font,
                scale_factor,
                direction,
                layout,
                width: UNWRAPPED,
                rows: Vec::new(),
                rows_valid: false,
                natural_width: None,
            });
        }
        let Some(cached) = cached.as_mut() else { return };
        if cached.width != width {
            cached.layout.set_width(if width == UNWRAPPED {
                -1
            } else {
                width * pango::SCALE
            });
            cached.width = width;
            cached.rows_valid = false;
        }
    }

    /// The width the text asks for on one row.
    fn natural_text_width(&self) -> i32 {
        self.prepare_layout(UNWRAPPED);
        let mut cached = self.imp().cached.borrow_mut();
        let Some(cached) = cached.as_mut() else { return MIN_WIDTH };
        let layout = &cached.layout;
        *cached
            .natural_width
            .get_or_insert_with(|| layout.pixel_size().0)
    }

    /// The height the text needs when wrapped to `for_size`, or on one row
    /// when no width is given.
    fn wrapped_text_height(&self, for_size: i32) -> i32 {
        self.prepare_layout(if for_size > 0 { for_size } else { UNWRAPPED });
        self.imp()
            .cached
            .borrow()
            .as_ref()
            .map_or(0, |cached| cached.layout.pixel_size().1)
    }

    fn ensure_layout(&self, width: i32) {
        self.prepare_layout(width);
        let mut cached = self.imp().cached.borrow_mut();
        let Some(cached) = cached.as_mut() else { return };
        if !cached.rows_valid {
            cached.rows = visual_rows(&cached.layout);
            cached.rows_valid = true;
        }
    }

    fn edge_for(&self, cached: &Cached, progress: LineProgress) -> SungEdge {
        match progress {
            LineProgress::NotStarted => SungEdge::Nothing,
            LineProgress::Done => SungEdge::Everything,
            LineProgress::Singing { word, fraction } => {
                let ranges = self.imp().ranges.borrow();
                let Some(&(start, end)) = ranges.get(word) else {
                    return SungEdge::Everything;
                };
                let scale = pango::SCALE as f32;
                let (line, from) = cached.layout.index_to_line_x(start as i32, false);
                let (end_line, to) = cached.layout.index_to_line_x(end as i32, false);
                let from = from as f32 / scale;
                let to = if end_line == line {
                    to as f32 / scale
                } else {
                    cached.rows.get(line as usize).map_or(from, |row| {
                        if row.rtl {
                            row.left
                        } else {
                            row.right
                        }
                    })
                };
                SungEdge::At {
                    line: line.max(0) as usize,
                    x: edge_inside(from, to, fraction),
                }
            }
        }
    }
}

fn same_edge(left: SungEdge, right: SungEdge) -> bool {
    match (left, right) {
        (SungEdge::At { line: a, x: ax }, SungEdge::At { line: b, x: bx }) => {
            a == b && (ax - bx).abs() < REDRAW_STEP
        }
        (a, b) => a == b,
    }
}

fn visual_rows(layout: &pango::Layout) -> Vec<VisualLine> {
    let scale = pango::SCALE as f32;
    let mut rows = Vec::new();
    let mut iter = layout.iter();
    loop {
        let (_, logical) = iter.line_extents();
        let rtl = iter
            .line_readonly()
            .is_some_and(|line| line.resolved_direction() == pango::Direction::Rtl);
        rows.push(VisualLine {
            top: logical.y() as f32 / scale,
            height: logical.height() as f32 / scale,
            left: logical.x() as f32 / scale,
            right: (logical.x() + logical.width()) as f32 / scale,
            rtl,
        });
        if !iter.next_line() {
            break;
        }
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rows_before_the_edge_are_sung_and_after_it_are_not() {
        let edge = SungEdge::At { line: 1, x: 40.0 };
        assert_eq!(
            fills(3, edge),
            vec![Fill::Sung, Fill::Edge(40.0), Fill::Unsung]
        );
    }

    #[test]
    fn nothing_and_everything_fill_every_row_alike() {
        assert_eq!(fills(2, SungEdge::Nothing), vec![Fill::Unsung, Fill::Unsung]);
        assert_eq!(
            fills(2, SungEdge::Everything),
            vec![Fill::Sung, Fill::Sung]
        );
    }

    #[test]
    fn the_edge_moves_through_a_word_in_proportion() {
        assert_eq!(edge_inside(10.0, 50.0, 0.0), 10.0);
        assert_eq!(edge_inside(10.0, 50.0, 0.5), 30.0);
        assert_eq!(edge_inside(10.0, 50.0, 2.0), 50.0);
    }

    #[test]
    fn a_sub_pixel_move_is_not_a_redraw() {
        let a = SungEdge::At { line: 0, x: 10.0 };
        assert!(same_edge(a, SungEdge::At { line: 0, x: 10.3 }));
        assert!(!same_edge(a, SungEdge::At { line: 0, x: 10.8 }));
        assert!(!same_edge(a, SungEdge::At { line: 1, x: 10.0 }));
        assert!(same_edge(SungEdge::Nothing, SungEdge::Nothing));
        assert!(!same_edge(SungEdge::Nothing, SungEdge::Everything));
    }
}
