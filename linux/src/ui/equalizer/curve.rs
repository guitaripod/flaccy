//! The response curve as a widget: a Cairo canvas that paints
//! `flaccy_shared`'s plot model through `render`, and turns the pointer and
//! the keyboard into events. The pointer rules (which band a press grabs, how
//! a drag settles, what a double press does) are the shared `PlotInteraction`;
//! this file only feeds it points and relays what it decides.

use super::copy;
use super::render::{self, CurveMemo, PlotCache, PlotFrame, Rgb, Style};
use crate::ui::screen::is_watched;
use adw::prelude::*;
use flaccy_shared::equalizer::graphic::GraphicSolver;
use flaccy_shared::equalizer::interaction::{PlotAction, PlotInteraction};
use flaccy_shared::equalizer::plot::EqualizerPlot;
use flaccy_shared::equalizer::plot_model::{PlotContent, PlotMode, PlotModel, Point, Rect};
use flaccy_shared::equalizer::profile::EqualizerBand;
use gtk::{gdk, glib};
use std::cell::{Cell, RefCell};
use std::rc::Rc;

const FRAME_INTERVAL: f64 = 1.0 / 30.0;
const FRAME_DURATION: std::time::Duration = std::time::Duration::from_millis(33);
/// Frames in a row with nothing moving after which the frame clock is let go.
const IDLE_FRAMES_BEFORE_PARKING: u32 = 45;
/// How often a parked curve looks for audio to start drawing again.
const PARKED_POLL_MS: u64 = 300;
/// How long the previewed curve takes to glide from the one before it.
const PREVIEW_MORPH_SECONDS: f64 = 0.16;
const WHEEL_Q_PER_NOTCH: f64 = 6.0;
const GAIN_STEP: f64 = 0.5;
const COARSE_GAIN_STEP: f64 = 2.0;
const FINE_GAIN_STEP: f64 = 0.1;

/// What the curve asks its owner to do.
#[derive(Clone, Debug, PartialEq)]
pub enum CurveEvent {
    Plot(PlotAction),
    ScaleQ { factor: f64, index: usize },
    StepGain { delta: f64, index: usize },
    SelectBy(i32),
    ResetSelected,
    DeleteSelected,
    BeginCompare,
    EndCompare,
}

/// The points of the previewed curve and of the one it glides from.
#[derive(Default)]
struct PreviewMemos {
    to: CurveMemo,
    from: CurveMemo,
}

type Handler = Rc<dyn Fn(CurveEvent)>;
type SpectrumSource = Rc<dyn Fn() -> Option<Vec<f32>>>;

pub struct CurveView {
    pub area: gtk::DrawingArea,
    model: RefCell<PlotModel>,
    interaction: RefCell<PlotInteraction>,
    hover: Cell<Option<usize>>,
    preview: RefCell<Option<Vec<EqualizerBand>>>,
    preview_from: RefCell<Vec<EqualizerBand>>,
    preview_morph: Cell<f64>,
    handler: RefCell<Option<Handler>>,
    spectrum: RefCell<Option<SpectrumSource>>,
    timer: RefCell<Option<glib::SourceId>>,
    plot_cache: RefCell<PlotCache>,
    preview_memos: RefCell<PreviewMemos>,
    spectrum_signature: Cell<f32>,
    comparing_with_key: Cell<bool>,
    wanted: Cell<bool>,
    parked: Cell<bool>,
    parking: Cell<bool>,
    idle_frames: Cell<u32>,
    on_frame: RefCell<Option<Rc<dyn Fn()>>>,
    poll: RefCell<Option<glib::SourceId>>,
}

/// The step a gain key moves by under the held modifiers.
pub fn gain_step(shift: bool, alt: bool) -> f64 {
    if shift {
        COARSE_GAIN_STEP
    } else if alt {
        FINE_GAIN_STEP
    } else {
        GAIN_STEP
    }
}

/// The Q multiplier one wheel movement of `delta` lines applies; scrolling up
/// narrows nothing and widens the band, as on the Mac.
pub fn wheel_q_factor(delta: f64) -> f64 {
    2f64.powf(delta / WHEEL_Q_PER_NOTCH)
}

/// The curve in words, for assistive technology and the tooltip: every band
/// with its value, and which one is selected.
pub fn describe(content: &PlotContent) -> String {
    match content.mode {
        PlotMode::Simple => {
            let bands: Vec<String> = GraphicSolver::CENTRES
                .iter()
                .enumerate()
                .map(|(index, &centre)| {
                    let value = content.targets.get(index).copied().unwrap_or(0.0);
                    format!("{} {} dB", copy::hertz(centre), copy::decibels(value))
                })
                .collect();
            let selected = GraphicSolver::CENTRES
                .get(content.selected_index)
                .map(|&centre| format!(" Selected band {}.", copy::hertz(centre)))
                .unwrap_or_default();
            format!("Simple mode, ten bands: {}.{selected}", bands.join(", "))
        }
        PlotMode::Advanced => {
            let bands: Vec<String> = content
                .bands
                .iter()
                .enumerate()
                .map(|(index, band)| {
                    let gain = if band.filter_type.has_gain() {
                        format!(" {} dB", copy::decibels(band.gain))
                    } else {
                        String::new()
                    };
                    let state = if band.is_enabled { "" } else { ", off" };
                    format!(
                        "band {}, {} {}{gain}, Q {}{state}",
                        index + 1,
                        copy::type_name(band.filter_type),
                        copy::hertz(band.frequency),
                        copy::q(band.q)
                    )
                })
                .collect();
            let selected = if content.bands.is_empty() {
                String::new()
            } else {
                format!(" Selected band {}.", content.selected_index + 1)
            };
            format!("Advanced mode, {} bands: {}.{selected}", content.bands.len(), bands.join("; "))
        }
    }
}

/// The text of the hover tooltip for a node.
pub fn node_tooltip(content: &PlotContent, targets: &[f64], index: usize) -> Option<String> {
    match content.mode {
        PlotMode::Simple => {
            let centre = GraphicSolver::CENTRES.get(index)?;
            let value = targets.get(index)?;
            Some(format!("{}  {} dB", copy::hertz(*centre), copy::decibels(*value)))
        }
        PlotMode::Advanced => {
            let band = content.bands.get(index)?;
            Some(if band.filter_type.has_gain() {
                format!(
                    "{}  {} dB  Q {}",
                    copy::hertz(band.frequency),
                    copy::decibels(band.gain),
                    copy::q(band.q)
                )
            } else {
                format!("{}  Q {}", copy::hertz(band.frequency), copy::q(band.q))
            })
        }
    }
}

fn ink(is_dark: bool) -> Rgb {
    if is_dark {
        (1.0, 1.0, 1.0)
    } else {
        (0.09, 0.09, 0.13)
    }
}

/// The accent as the plot paints it: the theme accent, lifted a little on a
/// dark surface so the glow reads.
pub fn plot_accent(is_dark: bool) -> Rgb {
    let (r, g, b) = crate::theme::accent_tint();
    if is_dark {
        let lift = 0.14;
        (r + (1.0 - r) * lift, g + (1.0 - g) * lift, b + (1.0 - b) * lift)
    } else {
        (r, g, b)
    }
}

impl CurveView {
    pub fn new() -> Rc<Self> {
        let area = gtk::DrawingArea::builder()
            .hexpand(true)
            .vexpand(true)
            .focusable(true)
            .can_focus(true)
            .content_height(280)
            .content_width(420)
            .has_tooltip(true)
            .accessible_role(gtk::AccessibleRole::Slider)
            .build();
        area.add_css_class("eq-curve");
        area.set_cursor_from_name(Some("crosshair"));
        area.update_property(&[
            gtk::accessible::Property::Label("Equalizer response curve"),
            gtk::accessible::Property::ValueMin(-12.0),
            gtk::accessible::Property::ValueMax(12.0),
        ]);
        let view = Rc::new(Self {
            area,
            model: RefCell::new(PlotModel::new()),
            interaction: RefCell::new(PlotInteraction::new()),
            hover: Cell::new(None),
            preview: RefCell::new(None),
            preview_from: RefCell::new(Vec::new()),
            preview_morph: Cell::new(1.0),
            handler: RefCell::new(None),
            spectrum: RefCell::new(None),
            timer: RefCell::new(None),
            plot_cache: RefCell::new(PlotCache::default()),
            preview_memos: RefCell::new(PreviewMemos::default()),
            spectrum_signature: Cell::new(0.0),
            comparing_with_key: Cell::new(false),
            wanted: Cell::new(false),
            parked: Cell::new(false),
            parking: Cell::new(false),
            idle_frames: Cell::new(0),
            on_frame: RefCell::new(None),
            poll: RefCell::new(None),
        });
        view.install();
        view
    }

    pub fn set_handler(&self, handler: impl Fn(CurveEvent) + 'static) {
        *self.handler.borrow_mut() = Some(Rc::new(handler));
    }

    pub fn set_spectrum_source(&self, source: Option<SpectrumSource>) {
        *self.spectrum.borrow_mut() = source;
    }

    /// Where a frequency and a gain land on the canvas, for driving the curve
    /// from a script.
    pub fn point_at(&self, frequency: f64, decibels: f64) -> Point {
        let plot = self.plot_rect();
        Point {
            x: plot.min_x() + EqualizerPlot::x_for_frequency(frequency, plot.width),
            y: plot.min_y() + EqualizerPlot::y_for_decibels(decibels, plot.height),
        }
    }

    pub fn selected_index(&self) -> usize {
        self.model.borrow().content().selected_index
    }

    /// Whether the frame clock has been let go because nothing is moving.
    pub fn is_parked(&self) -> bool {
        self.parked.get()
    }

    pub fn is_dragging(&self) -> bool {
        self.model.borrow().is_dragging
    }

    pub fn is_dark() -> bool {
        adw::StyleManager::default().is_dark()
    }

    pub fn update(self: &Rc<Self>, content: PlotContent, animated: bool) {
        let reduce_motion = !gtk::Settings::default().is_some_and(|s| s.is_gtk_enable_animations());
        let description = describe(&content);
        let value = match content.mode {
            PlotMode::Simple => content.targets.get(content.selected_index).copied().unwrap_or(0.0),
            PlotMode::Advanced => content
                .bands
                .get(content.selected_index)
                .map(|band| if band.filter_type.has_gain() { band.gain } else { 0.0 })
                .unwrap_or(0.0),
        };
        self.model.borrow_mut().update(content, !animated || reduce_motion);
        self.area.update_property(&[
            gtk::accessible::Property::Description(&description),
            gtk::accessible::Property::ValueNow(value),
            gtk::accessible::Property::ValueText(&format!("{} dB", copy::decibels(value))),
        ]);
        self.area.queue_draw();
        self.wake();
    }

    /// Shows the curve of a preset being auditioned as the line being heard,
    /// gliding from whatever was on screen; `None` goes back to the curve in force.
    pub fn set_preview(self: &Rc<Self>, bands: Option<Vec<EqualizerBand>>) {
        let reduce_motion = !gtk::Settings::default().is_some_and(|s| s.is_gtk_enable_animations());
        match bands {
            Some(target) => {
                let from = self.preview.borrow().clone().unwrap_or_else(|| self.kept_bands());
                *self.preview_from.borrow_mut() = from;
                *self.preview.borrow_mut() = Some(target);
                self.preview_morph.set(if reduce_motion { 1.0 } else { 0.0 });
            }
            None => {
                if self.preview.borrow_mut().take().is_none() {
                    return;
                }
                self.preview_morph.set(1.0);
            }
        }
        self.area.queue_draw();
        self.wake();
    }

    pub fn is_previewing(&self) -> bool {
        self.preview.borrow().is_some()
    }

    fn kept_bands(&self) -> Vec<EqualizerBand> {
        let model = self.model.borrow();
        if model.content().is_enabled {
            model.resolved_bands().to_vec()
        } else {
            Vec::new()
        }
    }

    /// The previewed curve placed on the plot, part-way from the one before it
    /// while the glide plays.
    fn preview_points(&self, plot: Rect) -> Option<Vec<Point>> {
        let preview = self.preview.borrow();
        let target = preview.as_ref()?;
        let model = self.model.borrow();
        let mut memos = self.preview_memos.borrow_mut();
        let memos = &mut *memos;
        let to = memos.to.points(&model, target, plot);
        let progress = self.preview_morph.get();
        if progress >= 1.0 {
            return Some(to.to_vec());
        }
        let from = memos.from.points(&model, &self.preview_from.borrow(), plot);
        let eased = progress * progress * (3.0 - 2.0 * progress);
        Some(
            from.iter()
                .zip(to)
                .map(|(from, to)| Point { x: to.x, y: from.y + (to.y - from.y) * eased })
                .collect(),
        )
    }

    /// The plot rectangle inside the canvas, with room for the axis labels.
    fn plot_rect(&self) -> Rect {
        let k = crate::ui::ui_scale::current();
        let (left, right, top, bottom) = (48.0 * k, 18.0 * k, 20.0 * k, 40.0 * k);
        Rect {
            x: left,
            y: top,
            width: (self.area.width() as f64 - left - right).max(10.0),
            height: (self.area.height() as f64 - top - bottom).max(10.0),
        }
    }

    fn style(&self, is_enabled: bool, is_comparing: bool) -> Style {
        let is_dark = Self::is_dark();
        Style {
            accent: plot_accent(is_dark),
            ink: ink(is_dark),
            is_dark,
            is_enabled,
            is_comparing,
            scale: crate::ui::ui_scale::current(),
        }
    }

    fn paint(&self, cr: &gtk::cairo::Context, width: i32, is_enabled: bool, is_comparing: bool) {
        let plot = self.plot_rect();
        let preview = self.preview_points(plot);
        let model = self.model.borrow();
        let has_focus = self.area.has_focus() && self.area.is_focus();
        let frame = PlotFrame {
            preview: preview.as_deref(),
            cache: &self.plot_cache,
            width: width as f64,
            plot,
            model: &model,
            style: self.style(is_enabled, is_comparing),
            hover: self.hover.get(),
            shows_focus: has_focus && self.area.root().is_some_and(|root| {
                root.downcast_ref::<gtk::Window>().is_some_and(|window| window.gets_focus_visible())
            }),
        };
        render::draw(cr, &frame);
    }

    fn emit(&self, event: CurveEvent) {
        let handler = self.handler.borrow().clone();
        if let Some(handler) = handler {
            handler(event);
        }
    }

    fn emit_actions(&self, actions: Vec<PlotAction>) {
        for action in actions {
            self.emit(CurveEvent::Plot(action));
        }
    }

    /// A press at `point`, with the event time in seconds.
    pub fn press(self: &Rc<Self>, point: Point, time: f64) {
        self.wake();
        let plot = self.plot_rect();
        let actions = {
            let mut model = self.model.borrow_mut();
            let mut interaction = self.interaction.borrow_mut();
            interaction.node_hit_radius = 32.0 * crate::ui::ui_scale::current();
            interaction.begin(&mut model, point, plot, time)
        };
        self.emit_actions(actions);
        self.area.queue_draw();
    }

    pub fn drag(&self, point: Point) {
        let plot = self.plot_rect();
        let actions = self.interaction.borrow_mut().move_to(&self.model.borrow(), point, plot);
        self.emit_actions(actions);
        self.area.queue_draw();
    }

    pub fn release(&self) {
        let actions = {
            let mut model = self.model.borrow_mut();
            self.interaction.borrow_mut().end(&mut model)
        };
        self.emit_actions(actions);
        self.area.queue_draw();
    }

    fn node_under(&self, point: Point) -> Option<usize> {
        let plot = self.plot_rect();
        let model = self.model.borrow();
        match model.content().mode {
            PlotMode::Advanced => {
                model.nearest_node(point, plot, 20.0 * crate::ui::ui_scale::current())
            }
            PlotMode::Simple => plot
                .contains(point)
                .then(|| EqualizerPlot::nearest_centre_index(point.x - plot.min_x(), plot.width)),
        }
    }

    fn set_hover(&self, hover: Option<usize>) {
        if self.hover.replace(hover) != hover {
            self.area.queue_draw();
        }
    }

    /// Handles a key on the curve; true when it was one the curve owns.
    pub fn key_pressed(&self, key: gdk::Key, state: gdk::ModifierType) -> bool {
        if state.intersects(gdk::ModifierType::CONTROL_MASK | gdk::ModifierType::SUPER_MASK) {
            return false;
        }
        let step = gain_step(
            state.contains(gdk::ModifierType::SHIFT_MASK),
            state.contains(gdk::ModifierType::ALT_MASK),
        );
        let index = self.selected_index();
        match key {
            gdk::Key::Left | gdk::Key::KP_Left => self.emit(CurveEvent::SelectBy(-1)),
            gdk::Key::Right | gdk::Key::KP_Right => self.emit(CurveEvent::SelectBy(1)),
            gdk::Key::Up | gdk::Key::KP_Up => self.emit(CurveEvent::StepGain { delta: step, index }),
            gdk::Key::Down | gdk::Key::KP_Down => self.emit(CurveEvent::StepGain { delta: -step, index }),
            gdk::Key::Delete | gdk::Key::BackSpace | gdk::Key::KP_Delete => {
                self.emit(CurveEvent::DeleteSelected)
            }
            gdk::Key::_0 | gdk::Key::KP_0 => self.emit(CurveEvent::ResetSelected),
            gdk::Key::c | gdk::Key::C => {
                if !self.comparing_with_key.replace(true) {
                    self.emit(CurveEvent::BeginCompare);
                }
            }
            _ => return false,
        }
        true
    }

    pub fn key_released(&self, key: gdk::Key) {
        if matches!(key, gdk::Key::c | gdk::Key::C) && self.comparing_with_key.replace(false) {
            self.emit(CurveEvent::EndCompare);
        }
    }

    fn scrolled(&self, dy: f64) -> bool {
        let index = self.hover.get().unwrap_or_else(|| self.selected_index());
        let mode = self.model.borrow().content().mode;
        if index >= self.model.borrow().node_count() || dy.abs() < 0.01 {
            return false;
        }
        match mode {
            PlotMode::Advanced => self.emit(CurveEvent::ScaleQ { factor: wheel_q_factor(dy), index }),
            PlotMode::Simple => self.emit(CurveEvent::StepGain {
                delta: if dy < 0.0 { GAIN_STEP } else { -GAIN_STEP },
                index,
            }),
        }
        true
    }

    /// Starts the frame timer: the spectrum rises and falls and the preset
    /// glide plays out, repainting only on a frame where something moved. When
    /// nothing has moved for a while the timer is let go, and a slow poll
    /// brings it back once there is audio to draw or the content changes.
    pub fn start_frames(self: &Rc<Self>, on_frame: impl Fn() + 'static) {
        *self.on_frame.borrow_mut() = Some(Rc::new(on_frame));
        self.wanted.set(true);
        self.run_frames();
    }

    pub fn stop_frames(&self) {
        self.wanted.set(false);
        self.parked.set(false);
        self.release_timer();
        if let Some(poll) = self.poll.borrow_mut().take() {
            poll.remove();
        }
    }

    fn release_timer(&self) {
        if let Some(timer) = self.timer.borrow_mut().take() {
            timer.remove();
        }
    }

    fn run_frames(self: &Rc<Self>) {
        if let Some(poll) = self.poll.borrow_mut().take() {
            poll.remove();
        }
        self.parked.set(false);
        self.idle_frames.set(0);
        if self.timer.borrow().is_some() {
            return;
        }
        let view = Rc::downgrade(self);
        let timer = glib::timeout_add_local(FRAME_DURATION, move || {
            if let Some(view) = view.upgrade() {
                view.frame();
            }
            glib::ControlFlow::Continue
        });
        *self.timer.borrow_mut() = Some(timer);
    }

    /// One tick of the frame timer. A curve nobody can see (unmapped, or its
    /// window suspended) has nothing to animate, so it parks at once.
    fn frame(self: &Rc<Self>) {
        if !is_watched(&self.area) {
            self.idle_frames.set(IDLE_FRAMES_BEFORE_PARKING);
            self.park_soon();
            return;
        }
        let active = self.advance();
        let callback = self.on_frame.borrow().clone();
        if let Some(callback) = callback {
            callback();
        }
        if active {
            self.idle_frames.set(0);
        } else if self.idle_frames.get() + 1 >= IDLE_FRAMES_BEFORE_PARKING {
            self.park_soon();
        } else {
            self.idle_frames.set(self.idle_frames.get() + 1);
        }
    }

    /// Parks from an idle callback, because a timer callback should not remove
    /// its own source while it is running.
    fn park_soon(self: &Rc<Self>) {
        if self.parking.replace(true) {
            return;
        }
        let view = Rc::downgrade(self);
        glib::idle_add_local_once(move || {
            if let Some(view) = view.upgrade() {
                view.parking.set(false);
                if view.wanted.get() && !view.parked.get() && view.idle_frames.get() > 0 {
                    view.park();
                }
            }
        });
    }

    /// Lets go of the frame clock until something wants drawing again.
    fn park(self: &Rc<Self>) {
        self.release_timer();
        self.parked.set(true);
        let view = Rc::downgrade(self);
        let poll = glib::timeout_add_local(std::time::Duration::from_millis(PARKED_POLL_MS), move || {
            let Some(view) = view.upgrade() else {
                return glib::ControlFlow::Break;
            };
            if !view.wanted.get() {
                return glib::ControlFlow::Break;
            }
            let source = view.spectrum.borrow().clone();
            if is_watched(&view.area) && source.and_then(|source| source()).is_some() {
                *view.poll.borrow_mut() = None;
                view.run_frames();
                return glib::ControlFlow::Break;
            }
            glib::ControlFlow::Continue
        });
        *self.poll.borrow_mut() = Some(poll);
    }

    /// Brings a parked frame clock back, for a change the curve has to show.
    fn wake(self: &Rc<Self>) {
        if self.wanted.get() && self.parked.get() {
            self.run_frames();
        }
    }

    /// One frame of animation; true when anything on screen moved or sound is arriving.
    fn advance(&self) -> bool {
        let reduce_motion = !gtk::Settings::default().is_some_and(|s| s.is_gtk_enable_animations());
        let source = self.spectrum.borrow().clone();
        let fresh = source.as_ref().and_then(|source| source());
        let arriving = fresh.is_some();
        let moved = self
            .model
            .borrow_mut()
            .step(fresh.as_deref(), source.is_none() || reduce_motion);
        let gliding = self.preview_morph.get() < 1.0;
        if gliding {
            let step = FRAME_INTERVAL / PREVIEW_MORPH_SECONDS;
            self.preview_morph.set((self.preview_morph.get() + step).min(1.0));
        }
        let signature: f32 = self.model.borrow().spectrum_bins().iter().sum();
        let changed = signature != self.spectrum_signature.replace(signature);
        let moved = moved || gliding;
        if moved || changed {
            self.area.queue_draw();
        }
        moved || changed || arriving || self.model.borrow().is_dragging
    }

    fn install(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);

        let drag = gtk::GestureDrag::builder().button(gdk::BUTTON_PRIMARY).build();
        {
            let view = weak.clone();
            drag.connect_drag_begin(move |gesture, x, y| {
                let Some(view) = view.upgrade() else { return };
                view.area.grab_focus();
                let time = gesture.current_event_time() as f64 / 1000.0;
                view.press(Point { x, y }, time);
            });
        }
        {
            let view = weak.clone();
            drag.connect_drag_update(move |gesture, dx, dy| {
                let Some(view) = view.upgrade() else { return };
                if let Some((x, y)) = gesture.start_point() {
                    view.drag(Point { x: x + dx, y: y + dy });
                }
            });
        }
        {
            let view = weak.clone();
            drag.connect_drag_end(move |_, _, _| {
                if let Some(view) = view.upgrade() {
                    view.release();
                }
            });
        }
        self.area.add_controller(drag);

        let motion = gtk::EventControllerMotion::new();
        {
            let view = weak.clone();
            motion.connect_motion(move |_, x, y| {
                if let Some(view) = view.upgrade() {
                    if !view.is_dragging() {
                        view.set_hover(view.node_under(Point { x, y }));
                    }
                }
            });
        }
        {
            let view = weak.clone();
            motion.connect_leave(move |_| {
                if let Some(view) = view.upgrade() {
                    view.set_hover(None);
                }
            });
        }
        self.area.add_controller(motion);

        let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::VERTICAL);
        {
            let view = weak.clone();
            scroll.connect_scroll(move |_, _, dy| {
                let handled = view.upgrade().is_some_and(|view| view.scrolled(dy));
                if handled {
                    glib::Propagation::Stop
                } else {
                    glib::Propagation::Proceed
                }
            });
        }
        self.area.add_controller(scroll);

        let keys = gtk::EventControllerKey::new();
        {
            let view = weak.clone();
            keys.connect_key_pressed(move |_, key, _, state| {
                let handled = view.upgrade().is_some_and(|view| view.key_pressed(key, state));
                if handled {
                    glib::Propagation::Stop
                } else {
                    glib::Propagation::Proceed
                }
            });
        }
        {
            let view = weak.clone();
            keys.connect_key_released(move |_, key, _, _| {
                if let Some(view) = view.upgrade() {
                    view.key_released(key);
                }
            });
        }
        self.area.add_controller(keys);

        {
            let view = weak.clone();
            self.area.connect_query_tooltip(move |_, x, y, _, tooltip| {
                let Some(view) = view.upgrade() else { return false };
                let Some(index) = view.node_under(Point { x: x as f64, y: y as f64 }) else {
                    return false;
                };
                let model = view.model.borrow();
                match node_tooltip(model.content(), model.display_targets(), index) {
                    Some(text) => {
                        tooltip.set_text(Some(&text));
                        true
                    }
                    None => false,
                }
            });
        }

        {
            let view = weak.clone();
            self.area.set_draw_func(move |_, cr, width, _| {
                if let Some(view) = view.upgrade() {
                    let (enabled, comparing) = {
                        let model = view.model.borrow();
                        (model.content().is_enabled, model.content().is_comparing)
                    };
                    view.paint(cr, width, enabled, comparing);
                }
            });
        }
        if let Some(theme) = crate::theme::ThemeController::current() {
            theme.connect_changed_widget(&self.area, |area| area.queue_draw());
        }
        self.area
            .connect_has_focus_notify(|area| area.queue_draw());
        adw::StyleManager::default().connect_dark_notify({
            let area = self.area.downgrade();
            move |_| {
                if let Some(area) = area.upgrade() {
                    area.queue_draw();
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use flaccy_shared::equalizer::biquad::FilterType;
    use flaccy_shared::equalizer::profile::EqualizerBand;

    #[test]
    fn the_gain_keys_step_by_the_held_modifier() {
        assert_eq!(gain_step(false, false), 0.5);
        assert_eq!(gain_step(true, false), 2.0);
        assert_eq!(gain_step(false, true), 0.1);
        assert_eq!(gain_step(true, true), 2.0);
    }

    #[test]
    fn a_wheel_notch_changes_q_by_a_tenth_or_so_in_each_direction() {
        let up = wheel_q_factor(-1.0);
        let down = wheel_q_factor(1.0);
        assert!(up < 1.0 && down > 1.0);
        assert!((up * down - 1.0).abs() < 1e-12);
        assert_eq!(wheel_q_factor(0.0), 1.0);
    }

    #[test]
    fn the_simple_curve_is_described_band_by_band() {
        let mut content = PlotContent::default();
        content.targets[3] = 4.0;
        content.selected_index = 3;
        let text = describe(&content);
        assert!(text.starts_with("Simple mode, ten bands: 32 Hz 0.0 dB, 64 Hz 0.0 dB"));
        assert!(text.contains("250 Hz +4.0 dB"));
        assert!(text.ends_with("Selected band 250 Hz."));
    }

    #[test]
    fn the_advanced_curve_names_each_filter() {
        let content = PlotContent {
            mode: PlotMode::Advanced,
            bands: vec![
                EqualizerBand::new(FilterType::HighPass, 28.0, 0.0, None, true),
                EqualizerBand::new(FilterType::Bell, 3300.0, 2.6, Some(1.4), false),
            ],
            selected_index: 1,
            ..PlotContent::default()
        };
        let text = describe(&content);
        assert!(text.contains("band 1, High-pass 28 Hz, Q 0.71"));
        assert!(text.contains("band 2, Bell 3.3 kHz +2.6 dB, Q 1.40, off"));
        assert!(text.ends_with("Selected band 2."));
    }

    #[test]
    fn a_node_tooltip_gives_the_exact_values() {
        let content = PlotContent {
            mode: PlotMode::Advanced,
            bands: vec![EqualizerBand::new(FilterType::Bell, 1000.0, -2.25, Some(2.0), true)],
            ..PlotContent::default()
        };
        assert_eq!(
            node_tooltip(&content, &[], 0).as_deref(),
            Some("1 kHz  \u{2212}2.3 dB  Q 2.00")
        );
        assert_eq!(node_tooltip(&content, &[], 4), None);
        let mut targets = vec![0.0; 10];
        targets[9] = 12.0;
        assert_eq!(
            node_tooltip(&PlotContent::default(), &targets, 9).as_deref(),
            Some("16 kHz  +12.0 dB")
        );
    }
}
