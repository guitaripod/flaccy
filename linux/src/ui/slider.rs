use crate::ui::FrameDriver;
use gtk::prelude::*;
use gtk::{cairo, gdk, glib, graphene};
use std::cell::{Cell, RefCell};
use std::f64::consts::{FRAC_PI_2, PI, TAU};
use std::rc::Rc;
use std::time::Duration;

/// Proportions of one slider: the height of its hit area, how thick the bar
/// sits at rest and under the pointer, the knob that grows in as the pointer
/// arrives, and how strongly the unfilled track shows.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SliderMetrics {
    pub height: i32,
    pub rest: f64,
    pub active: f64,
    pub knob: f64,
    pub track_alpha: f64,
}

impl SliderMetrics {
    /// The seek bar along the bottom transport strip.
    pub const TRANSPORT: SliderMetrics = SliderMetrics {
        height: 20,
        rest: 4.0,
        active: 6.0,
        knob: 6.5,
        track_alpha: 0.16,
    };
    /// The seek bar in the Now Playing dock.
    pub const HERO: SliderMetrics = SliderMetrics {
        height: 24,
        rest: 6.0,
        active: 8.0,
        knob: 7.5,
        track_alpha: 0.2,
    };
    /// Every volume slider.
    pub const VOLUME: SliderMetrics = SliderMetrics {
        height: 20,
        rest: 4.0,
        active: 6.0,
        knob: 6.0,
        track_alpha: 0.16,
    };

    /// Room kept at each end so the knob, grown to its held size, and its
    /// shadow never clip against the widget's edge.
    fn inset(&self) -> f64 {
        (self.knob * HELD_SCALE + 2.5).ceil()
    }
}

/// How much the knob swells while it is held.
const HELD_SCALE: f64 = 1.2;
/// Seconds for the bar to thicken and the knob to grow in as the pointer
/// arrives, and to settle back once it leaves.
const EMPHASIS_IN: f64 = 0.14;
const EMPHASIS_OUT: f64 = 0.22;
/// How long the bubble stays up after a key press or wheel notch moved the
/// value with no pointer to follow.
const REVEAL: Duration = Duration::from_millis(900);
/// Space between the bubble and the top of the slider's hit area.
const BUBBLE_GAP: f64 = 2.0;
/// Space the bubble keeps from its host's edges.
const BUBBLE_MARGIN: f64 = 4.0;
/// Movement below this many pixels is not worth a repaint.
const REPAINT_THRESHOLD: f64 = 0.25;
/// The wash between the playhead and a pointer hovering ahead of it.
const GHOST_ALPHA: f64 = 0.16;
/// Stacked halos under the filled part, widest and faintest first — Cairo has
/// no blur, and this reads as the soft glow the stylesheet used to draw.
const GLOW: [(f64, f64); 4] = [(6.0, 0.025), (4.0, 0.035), (2.5, 0.05), (1.2, 0.07)];

/// A request to move the value that did not come from the pointer: arrow keys
/// and wheel notches are `Fine`, Page Up/Down `Coarse`, Home/End `To`. The
/// owner decides what one step is worth.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Step {
    Fine(i32),
    Coarse(i32),
    To(f64),
}

/// The mapping between fractions and pixels for one allocated width, in
/// left-to-right coordinates.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Geometry {
    start: f64,
    span: f64,
}

impl Geometry {
    fn new(width: f64, inset: f64) -> Geometry {
        let start = inset.min(width / 2.0).max(0.0);
        Geometry {
            start,
            span: (width - 2.0 * start).max(1.0),
        }
    }

    fn fraction_at(&self, x: f64) -> f64 {
        ((x - self.start) / self.span).clamp(0.0, 1.0)
    }

    fn x_at(&self, fraction: f64) -> f64 {
        self.start + self.span * fraction.clamp(0.0, 1.0)
    }
}

#[derive(Clone, Copy)]
struct Hold {
    origin: f64,
    fraction: f64,
}

type Handler<T> = RefCell<Option<Rc<dyn Fn(T)>>>;
type Caption = RefCell<Option<Rc<dyn Fn(f64) -> String>>>;

struct Inner {
    area: gtk::DrawingArea,
    bubble: gtk::Label,
    drag: gtk::GestureDrag,
    metrics: SliderMetrics,
    value: Cell<f64>,
    /// The value the last paint put on screen. A playing track moves a
    /// fraction of a pixel per frame, so every change is measured against what
    /// is actually showing — never against the previous frame's value, which
    /// would never add up to a repaint.
    painted: Cell<f64>,
    held: Cell<Option<Hold>>,
    hover_x: Cell<Option<f64>>,
    revealed: Cell<bool>,
    reveal_timer: RefCell<Option<glib::SourceId>>,
    emphasis: Cell<f64>,
    enabled: Cell<bool>,
    ghost: Cell<bool>,
    driver: FrameDriver,
    caption: Caption,
    on_hold: Handler<f64>,
    on_move: Handler<f64>,
    on_release: Handler<f64>,
    on_cancel: Handler<()>,
    on_step: Handler<Step>,
}

/// A capsule slider drawn by hand, shared by the seek bars and the volume
/// controls. The bar thickens and a knob grows in under the pointer, a bubble
/// names the value a click would land on, and the owner hears a hold, every
/// move, and the release — or a cancel, when the hold ends any other way — so
/// it can decide what continuous input is allowed to cost. Keyboard and wheel
/// input arrive as `Step`s.
#[derive(Clone)]
pub struct Slider {
    inner: Rc<Inner>,
}

impl Slider {
    pub fn new(metrics: SliderMetrics, accessible_label: &str) -> Slider {
        let area = gtk::DrawingArea::builder()
            .accessible_role(gtk::AccessibleRole::Slider)
            .content_height(metrics.height)
            .focusable(true)
            .focus_on_click(false)
            .valign(gtk::Align::Center)
            .build();
        area.add_css_class("slider");
        area.update_property(&[
            gtk::accessible::Property::Label(accessible_label),
            gtk::accessible::Property::ValueMin(0.0),
            gtk::accessible::Property::ValueMax(1.0),
            gtk::accessible::Property::ValueNow(0.0),
        ]);

        let bubble = gtk::Label::builder()
            .accessible_role(gtk::AccessibleRole::Presentation)
            .can_target(false)
            .can_focus(false)
            .halign(gtk::Align::Start)
            .valign(gtk::Align::Start)
            .justify(gtk::Justification::Center)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .max_width_chars(44)
            .visible(false)
            .build();
        bubble.add_css_class("slider-bubble");

        let drag = gtk::GestureDrag::new();
        drag.set_button(gdk::BUTTON_PRIMARY);
        area.add_controller(drag.clone());

        let inner = Rc::new(Inner {
            area,
            bubble,
            drag,
            metrics,
            value: Cell::new(0.0),
            painted: Cell::new(0.0),
            held: Cell::new(None),
            hover_x: Cell::new(None),
            revealed: Cell::new(false),
            reveal_timer: RefCell::new(None),
            emphasis: Cell::new(0.0),
            enabled: Cell::new(true),
            ghost: Cell::new(false),
            driver: FrameDriver::default(),
            caption: RefCell::new(None),
            on_hold: RefCell::new(None),
            on_move: RefCell::new(None),
            on_release: RefCell::new(None),
            on_cancel: RefCell::new(None),
            on_step: RefCell::new(None),
        });
        wire_drawing(&inner);
        wire_pointer(&inner);
        wire_keys(&inner);
        wire_lifecycle(&inner);
        Slider { inner }
    }

    pub fn area(&self) -> &gtk::DrawingArea {
        &self.inner.area
    }

    /// The floating label naming the value under the pointer. The owner adds
    /// it to an overlay that covers the space above the slider, which is where
    /// it is placed.
    pub fn bubble(&self) -> &gtk::Label {
        &self.inner.bubble
    }

    pub fn set_value(&self, fraction: f64) {
        let inner = &self.inner;
        let fraction = if fraction.is_finite() {
            fraction.clamp(0.0, 1.0)
        } else {
            0.0
        };
        inner.value.set(fraction);
        if repaint_due(inner.painted.get(), fraction, inner.geometry().span) {
            inner.area.queue_draw();
            if inner.revealed.get() {
                inner.place_bubble();
            }
        }
    }

    pub fn set_enabled(&self, enabled: bool) {
        let inner = &self.inner;
        if inner.enabled.replace(enabled) == enabled {
            return;
        }
        if !enabled {
            self.abort_hold();
        }
        inner.refresh();
    }

    /// Washes the stretch between the playhead and a pointer hovering ahead of
    /// it, and dims the stretch a click behind it would give back — for a seek
    /// bar, where that difference is what the pointer is asking.
    pub fn set_ghost(&self, ghost: bool) {
        self.inner.ghost.set(ghost);
    }

    pub fn set_caption(&self, caption: impl Fn(f64) -> String + 'static) {
        *self.inner.caption.borrow_mut() = Some(Rc::new(caption));
    }

    pub fn connect_hold(&self, handler: impl Fn(f64) + 'static) {
        *self.inner.on_hold.borrow_mut() = Some(Rc::new(handler));
    }

    pub fn connect_move(&self, handler: impl Fn(f64) + 'static) {
        *self.inner.on_move.borrow_mut() = Some(Rc::new(handler));
    }

    pub fn connect_release(&self, handler: impl Fn(f64) + 'static) {
        *self.inner.on_release.borrow_mut() = Some(Rc::new(handler));
    }

    pub fn connect_cancel(&self, handler: impl Fn() + 'static) {
        *self.inner.on_cancel.borrow_mut() = Some(Rc::new(move |()| handler()));
    }

    pub fn connect_step(&self, handler: impl Fn(Step) + 'static) {
        *self.inner.on_step.borrow_mut() = Some(Rc::new(handler));
    }

    pub fn held_fraction(&self) -> Option<f64> {
        self.inner.held.get().map(|hold| hold.fraction)
    }

    pub fn is_held(&self) -> bool {
        self.inner.held.get().is_some()
    }

    /// Ends a hold without a release, for when what it was holding went away
    /// underneath it — the owner hears `cancel`, never `release`.
    pub fn abort_hold(&self) {
        self.inner.abort_hold();
    }

    /// Re-renders the bubble, for when the owner's caption changed meaning
    /// (a new duration) while the pointer stayed put.
    pub fn refresh_bubble(&self) {
        self.inner.place_bubble();
    }

    pub fn set_accessible_value(&self, max: f64, now: f64, text: &str) {
        self.inner.area.update_property(&[
            gtk::accessible::Property::ValueMax(max),
            gtk::accessible::Property::ValueNow(now),
            gtk::accessible::Property::ValueText(text),
        ]);
    }
}

impl Inner {
    fn geometry(&self) -> Geometry {
        Geometry::new(self.area.width() as f64, self.metrics.inset())
    }

    fn rtl(&self) -> bool {
        self.area.direction() == gtk::TextDirection::Rtl
    }

    /// Converts between widget coordinates and the left-to-right space the
    /// geometry and the drawing work in — the same flip both ways.
    fn mirrored(&self, x: f64) -> f64 {
        if self.rtl() {
            self.area.width() as f64 - x
        } else {
            x
        }
    }

    fn fraction_at(&self, x: f64) -> f64 {
        self.geometry().fraction_at(self.mirrored(x))
    }

    fn call<T>(&self, handler: &Handler<T>, value: T) {
        let handler = handler.borrow().clone();
        if let Some(handler) = handler {
            handler(value);
        }
    }

    fn emphasis_target(&self) -> f64 {
        let engaged = self.held.get().is_some()
            || self.hover_x.get().is_some()
            || self.revealed.get()
            || self.area.has_visible_focus();
        if self.enabled.get() && engaged {
            1.0
        } else {
            0.0
        }
    }

    /// Where the bubble points and whether a hold is placing it: a hold wins,
    /// then a value just moved from the keyboard, then plain hover.
    fn bubble_anchor(&self) -> Option<(f64, bool)> {
        if !self.enabled.get() {
            return None;
        }
        if let Some(hold) = self.held.get() {
            return Some((hold.fraction, true));
        }
        if self.revealed.get() {
            return Some((self.value.get(), false));
        }
        self.hover_x.get().map(|x| (self.fraction_at(x), false))
    }

    fn place_bubble(&self) {
        let bubble = &self.bubble;
        let Some((fraction, held)) = self.bubble_anchor() else {
            bubble.set_visible(false);
            return;
        };
        let caption = self.caption.borrow().clone();
        let (Some(caption), Some(host)) = (caption, bubble.parent()) else {
            bubble.set_visible(false);
            return;
        };
        if !self.area.is_mapped() {
            bubble.set_visible(false);
            return;
        }
        let markup = caption(fraction);
        if markup.is_empty() {
            bubble.set_visible(false);
            return;
        }
        if bubble.label() != markup {
            bubble.set_markup(&markup);
        }
        if held {
            bubble.add_css_class("held");
        } else {
            bubble.remove_css_class("held");
        }
        bubble.set_visible(true);
        let (width, height) = bubble_size(bubble);
        let x = self.mirrored(self.geometry().x_at(fraction));
        let Some(point) = self
            .area
            .compute_point(&host, &graphene::Point::new(x as f32, 0.0))
        else {
            bubble.set_visible(false);
            return;
        };
        let room = (host.width() as f64 - width as f64 - BUBBLE_MARGIN).max(BUBBLE_MARGIN);
        let left = (point.x() as f64 - width as f64 / 2.0).clamp(BUBBLE_MARGIN, room);
        let top = (point.y() as f64 - height as f64 - BUBBLE_GAP).max(0.0);
        bubble.set_margin_start(left.round() as i32);
        bubble.set_margin_top(top.round() as i32);
    }

    fn refresh(self: &Rc<Self>) {
        self.place_bubble();
        self.animate_emphasis();
        self.area.queue_draw();
    }

    fn animate_emphasis(self: &Rc<Self>) {
        let target = self.emphasis_target();
        if (self.emphasis.get() - target).abs() < 1e-3 {
            return;
        }
        if !animations_enabled() || !self.area.is_mapped() {
            self.emphasis.set(target);
            self.area.queue_draw();
            return;
        }
        let weak = Rc::downgrade(self);
        self.driver.start(&self.area, move |delta| {
            let Some(inner) = weak.upgrade() else {
                return;
            };
            let target = inner.emphasis_target();
            let current = inner.emphasis.get();
            let next = if target > current {
                (current + delta / EMPHASIS_IN).min(target)
            } else {
                (current - delta / EMPHASIS_OUT).max(target)
            };
            inner.emphasis.set(next);
            inner.area.queue_draw();
            if (next - target).abs() < 1e-3 {
                inner.emphasis.set(target);
                inner.driver.stop();
            }
        });
    }

    fn reveal(self: &Rc<Self>) {
        if let Some(timer) = self.reveal_timer.borrow_mut().take() {
            timer.remove();
        }
        self.revealed.set(true);
        let weak = Rc::downgrade(self);
        let timer = glib::timeout_add_local_once(REVEAL, move || {
            if let Some(inner) = weak.upgrade() {
                inner.reveal_timer.borrow_mut().take();
                inner.revealed.set(false);
                inner.refresh();
            }
        });
        *self.reveal_timer.borrow_mut() = Some(timer);
        self.refresh();
    }

    fn conceal(self: &Rc<Self>) {
        if let Some(timer) = self.reveal_timer.borrow_mut().take() {
            timer.remove();
        }
        self.revealed.set(false);
    }

    fn abort_hold(self: &Rc<Self>) {
        if self.held.take().is_none() {
            return;
        }
        self.drag.reset();
        self.refresh();
        self.call(&self.on_cancel, ());
    }

    fn draw(&self, cr: &cairo::Context, width: i32, height: i32) {
        let width = width as f64;
        let metrics = self.metrics;
        let geometry = Geometry::new(width, metrics.inset());
        let emphasis = ease(self.emphasis.get());
        let thickness = metrics.rest + (metrics.active - metrics.rest) * emphasis;
        let middle = (height as f64 / 2.0).round();
        if self.rtl() {
            cr.translate(width, 0.0);
            cr.scale(-1.0, 1.0);
        }

        let fg = self.area.color();
        let (fr, fgreen, fb) = (fg.red() as f64, fg.green() as f64, fg.blue() as f64);
        let (ar, ag, ab) = crate::theme::accent_tint();
        let start = geometry.start;
        let end = geometry.start + geometry.span;
        let enabled = self.enabled.get();
        let held = self.held.get();
        let fraction = held.map(|hold| hold.fraction).unwrap_or(self.value.get());
        self.painted.set(fraction);
        let head = geometry.x_at(fraction);

        cr.set_source_rgba(fr, fgreen, fb, metrics.track_alpha);
        capsule(cr, start, end, middle, thickness);
        let _ = cr.fill();

        let hover = self
            .hover_x
            .get()
            .filter(|_| enabled && self.ghost.get() && held.is_none())
            .map(|x| geometry.x_at(geometry.fraction_at(self.mirrored(x))));

        if let Some(ahead) = hover.filter(|x| *x > head) {
            cr.set_source_rgba(fr, fgreen, fb, GHOST_ALPHA * emphasis);
            capsule(cr, start, ahead, middle, thickness);
            let _ = cr.fill();
        }

        if !enabled {
            return;
        }
        if head > start {
            draw_fill(cr, (ar, ag, ab), start, head, hover, middle, thickness);
        }

        let grow = if held.is_some() { HELD_SCALE } else { 1.0 };
        let knob = metrics.knob * emphasis * grow;
        if knob < 0.4 {
            return;
        }
        cr.set_source_rgba(0.0, 0.0, 0.0, 0.12 * emphasis);
        cr.arc(head, middle + 1.0, knob + 1.8, 0.0, TAU);
        let _ = cr.fill();
        cr.set_source_rgba(0.0, 0.0, 0.0, 0.2 * emphasis);
        cr.arc(head, middle + 0.5, knob + 0.6, 0.0, TAU);
        let _ = cr.fill();
        cr.set_source_rgba(1.0, 1.0, 1.0, 1.0);
        cr.arc(head, middle, knob, 0.0, TAU);
        let _ = cr.fill();
        cr.set_source_rgba(ar, ag, ab, 0.35 * emphasis);
        cr.set_line_width(1.0);
        cr.arc(head, middle, (knob - 0.5).max(0.1), 0.0, TAU);
        let _ = cr.stroke();
    }
}

fn wire_drawing(inner: &Rc<Inner>) {
    let weak = Rc::downgrade(inner);
    inner.area.set_draw_func(move |_, cr, width, height| {
        if let Some(inner) = weak.upgrade() {
            inner.draw(cr, width, height);
        }
    });
    if let Some(controller) = crate::theme::ThemeController::current() {
        controller.connect_changed_widget(&inner.area, |area| area.queue_draw());
    }
}

fn wire_pointer(inner: &Rc<Inner>) {
    let motion = gtk::EventControllerMotion::new();
    {
        let weak = Rc::downgrade(inner);
        motion.connect_enter(move |_, x, _| {
            if let Some(inner) = weak.upgrade() {
                inner.hover_x.set(Some(x));
                inner.refresh();
            }
        });
    }
    {
        let weak = Rc::downgrade(inner);
        motion.connect_motion(move |_, x, _| {
            let Some(inner) = weak.upgrade() else {
                return;
            };
            if inner.hover_x.replace(Some(x)) == Some(x) {
                return;
            }
            inner.conceal();
            inner.refresh();
        });
    }
    {
        let weak = Rc::downgrade(inner);
        motion.connect_leave(move |_| {
            if let Some(inner) = weak.upgrade() {
                inner.hover_x.set(None);
                inner.refresh();
            }
        });
    }
    inner.area.add_controller(motion);

    {
        let weak = Rc::downgrade(inner);
        inner.drag.connect_drag_begin(move |gesture, x, _| {
            let Some(inner) = weak.upgrade() else {
                return;
            };
            if !inner.enabled.get() {
                gesture.set_state(gtk::EventSequenceState::Denied);
                return;
            }
            gesture.set_state(gtk::EventSequenceState::Claimed);
            let fraction = inner.fraction_at(x);
            inner.held.set(Some(Hold {
                origin: x,
                fraction,
            }));
            inner.conceal();
            inner.refresh();
            inner.call(&inner.on_hold, fraction);
        });
    }
    {
        let weak = Rc::downgrade(inner);
        inner.drag.connect_drag_update(move |_, dx, _| {
            let Some(inner) = weak.upgrade() else {
                return;
            };
            let Some(hold) = inner.held.get() else {
                return;
            };
            let fraction = inner.fraction_at(hold.origin + dx);
            if fraction == hold.fraction {
                return;
            }
            inner.held.set(Some(Hold { fraction, ..hold }));
            inner.refresh();
            inner.call(&inner.on_move, fraction);
        });
    }
    {
        let weak = Rc::downgrade(inner);
        inner.drag.connect_drag_end(move |_, dx, _| {
            let Some(inner) = weak.upgrade() else {
                return;
            };
            let Some(hold) = inner.held.take() else {
                return;
            };
            let fraction = inner.fraction_at(hold.origin + dx);
            inner.value.set(fraction);
            inner.refresh();
            inner.call(&inner.on_release, fraction);
        });
    }

    let scroll = gtk::EventControllerScroll::new(
        gtk::EventControllerScrollFlags::BOTH_AXES | gtk::EventControllerScrollFlags::DISCRETE,
    );
    {
        let weak = Rc::downgrade(inner);
        scroll.connect_scroll(move |_, dx, dy| {
            let Some(inner) = weak.upgrade() else {
                return glib::Propagation::Proceed;
            };
            if !inner.enabled.get() || inner.held.get().is_some() {
                return glib::Propagation::Proceed;
            }
            let horizontal = if inner.rtl() { -dx } else { dx };
            let notches = if dy.abs() >= dx.abs() { -dy } else { horizontal };
            let notches = notches.round() as i32;
            if notches != 0 {
                inner.reveal();
                inner.call(&inner.on_step, Step::Fine(notches));
            }
            glib::Propagation::Stop
        });
    }
    inner.area.add_controller(scroll);
}

fn wire_keys(inner: &Rc<Inner>) {
    let keys = gtk::EventControllerKey::new();
    let weak = Rc::downgrade(inner);
    keys.connect_key_pressed(move |_, key, _, modifiers| {
        let Some(inner) = weak.upgrade() else {
            return glib::Propagation::Proceed;
        };
        if !inner.enabled.get() || !modifiers.difference(gdk::ModifierType::LOCK_MASK).is_empty()
        {
            return glib::Propagation::Proceed;
        }
        let forward = if inner.rtl() { -1 } else { 1 };
        let step = match key {
            gdk::Key::Right | gdk::Key::KP_Right => Step::Fine(forward),
            gdk::Key::Left | gdk::Key::KP_Left => Step::Fine(-forward),
            gdk::Key::Up | gdk::Key::KP_Up => Step::Fine(1),
            gdk::Key::Down | gdk::Key::KP_Down => Step::Fine(-1),
            gdk::Key::Page_Up | gdk::Key::KP_Page_Up => Step::Coarse(1),
            gdk::Key::Page_Down | gdk::Key::KP_Page_Down => Step::Coarse(-1),
            gdk::Key::Home | gdk::Key::KP_Home => Step::To(0.0),
            gdk::Key::End | gdk::Key::KP_End => Step::To(1.0),
            _ => return glib::Propagation::Proceed,
        };
        inner.reveal();
        inner.call(&inner.on_step, step);
        glib::Propagation::Stop
    });
    inner.area.add_controller(keys);

    let focus = gtk::EventControllerFocus::new();
    {
        let weak = Rc::downgrade(inner);
        focus.connect_enter(move |_| {
            let weak = weak.clone();
            glib::idle_add_local_once(move || {
                if let Some(inner) = weak.upgrade() {
                    inner.refresh();
                }
            });
        });
    }
    {
        let weak = Rc::downgrade(inner);
        focus.connect_leave(move |_| {
            if let Some(inner) = weak.upgrade() {
                inner.refresh();
            }
        });
    }
    inner.area.add_controller(focus);
}

/// A slider taken off screen mid-gesture (Now Playing closing under a drag)
/// hears a cancel rather than a release, and comes back at rest.
fn wire_lifecycle(inner: &Rc<Inner>) {
    let weak = Rc::downgrade(inner);
    inner.area.connect_unmap(move |_| {
        let Some(inner) = weak.upgrade() else {
            return;
        };
        inner.hover_x.set(None);
        inner.conceal();
        inner.abort_hold();
        inner.driver.stop();
        inner.emphasis.set(0.0);
        inner.bubble.set_visible(false);
    });
}

/// The bubble's own size. GTK counts a widget's margins into what it measures,
/// and the margins are what place the bubble — measuring them in would push it
/// further off with every move.
fn bubble_size(bubble: &gtk::Label) -> (i32, i32) {
    let (_, width, _, _) = bubble.measure(gtk::Orientation::Horizontal, -1);
    let (_, height, _, _) = bubble.measure(gtk::Orientation::Vertical, -1);
    (
        width - bubble.margin_start() - bubble.margin_end(),
        height - bubble.margin_top() - bubble.margin_bottom(),
    )
}

/// The played stretch: a soft halo, then the accent gradient. A pointer
/// hovering behind the playhead dims the part a click there would give back.
fn draw_fill(
    cr: &cairo::Context,
    (ar, ag, ab): (f64, f64, f64),
    start: f64,
    head: f64,
    hover: Option<f64>,
    middle: f64,
    thickness: f64,
) {
    for (spread, alpha) in GLOW {
        cr.set_source_rgba(ar, ag, ab, alpha);
        capsule(
            cr,
            start - spread,
            head + spread,
            middle,
            thickness + 2.0 * spread,
        );
        let _ = cr.fill();
    }
    let behind = hover.filter(|x| *x < head);
    let gradient = |strength: f64| {
        let gradient = cairo::LinearGradient::new(start, 0.0, head, 0.0);
        gradient.add_color_stop_rgba(0.0, ar, ag, ab, 0.85 * strength);
        gradient.add_color_stop_rgba(1.0, ar, ag, ab, strength);
        gradient
    };
    let _ = cr.set_source(gradient(if behind.is_some() { 0.5 } else { 1.0 }));
    capsule(cr, start, head, middle, thickness);
    let _ = cr.fill();
    if let Some(behind) = behind {
        let _ = cr.set_source(gradient(1.0));
        capsule(cr, start, behind, middle, thickness);
        let _ = cr.fill();
    }
}

/// Traces a horizontal capsule from `from` to `to`, its ends fully rounded.
/// A capsule shorter than it is thick narrows its radius instead of bulging.
fn capsule(cr: &cairo::Context, from: f64, to: f64, middle: f64, thickness: f64) {
    let width = to - from;
    if width <= 0.0 || thickness <= 0.0 {
        return;
    }
    let radius = (thickness / 2.0).min(width / 2.0);
    let top = middle - thickness / 2.0;
    let bottom = middle + thickness / 2.0;
    cr.new_sub_path();
    cr.arc(to - radius, top + radius, radius, -FRAC_PI_2, 0.0);
    cr.arc(to - radius, bottom - radius, radius, 0.0, FRAC_PI_2);
    cr.arc(from + radius, bottom - radius, radius, FRAC_PI_2, PI);
    cr.arc(from + radius, top + radius, radius, PI, 3.0 * FRAC_PI_2);
    cr.close_path();
}

fn repaint_due(painted: f64, value: f64, span: f64) -> bool {
    (value - painted).abs() * span >= REPAINT_THRESHOLD
}

fn ease(t: f64) -> f64 {
    let t = t.clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Honors the desktop's "reduce animation" preference: the bar and knob snap
/// to their state instead of easing into it.
fn animations_enabled() -> bool {
    gtk::Settings::default().is_none_or(|settings| settings.is_gtk_enable_animations())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn geometry_keeps_the_knob_inside_the_widget() {
        let geometry = Geometry::new(200.0, SliderMetrics::TRANSPORT.inset());
        assert_eq!(geometry.x_at(0.0), SliderMetrics::TRANSPORT.inset());
        assert_eq!(geometry.x_at(1.0), 200.0 - SliderMetrics::TRANSPORT.inset());
    }

    #[test]
    fn pointer_and_playhead_share_one_mapping() {
        let geometry = Geometry::new(640.0, 11.0);
        for fraction in [0.0, 0.125, 0.5, 0.73, 1.0] {
            let x = geometry.x_at(fraction);
            assert!((geometry.fraction_at(x) - fraction).abs() < 1e-9);
        }
    }

    #[test]
    fn pointers_past_either_end_pin_to_it() {
        let geometry = Geometry::new(300.0, 10.0);
        assert_eq!(geometry.fraction_at(-40.0), 0.0);
        assert_eq!(geometry.fraction_at(3.0), 0.0);
        assert_eq!(geometry.fraction_at(295.0), 1.0);
        assert_eq!(geometry.fraction_at(900.0), 1.0);
    }

    #[test]
    fn a_sliver_of_a_widget_still_maps() {
        let geometry = Geometry::new(8.0, 11.0);
        assert!(geometry.span >= 1.0);
        assert!((0.0..=1.0).contains(&geometry.fraction_at(4.0)));
    }

    #[test]
    fn a_slow_playhead_still_repaints() {
        let span = 1700.0;
        let per_frame = 1.0 / (240.0 * 165.0);
        let mut painted = 0.0;
        let mut value = 0.0;
        let mut repaints = 0;
        for _ in 0..165 {
            value += per_frame;
            if repaint_due(painted, value, span) {
                painted = value;
                repaints += 1;
            }
        }
        assert!(repaints >= 20, "a four-minute track moved only {repaints} times in a second");
        assert!((value - painted) * span < REPAINT_THRESHOLD);
    }

    #[test]
    fn easing_starts_and_lands_exactly() {
        assert_eq!(ease(0.0), 0.0);
        assert_eq!(ease(1.0), 1.0);
        assert_eq!(ease(-3.0), 0.0);
        assert_eq!(ease(0.5), 0.5);
    }
}
