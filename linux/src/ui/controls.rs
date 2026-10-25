use crate::events::AppEvent;
use crate::library::Track;
use crate::player::RepeatMode;
use crate::ui::screen::is_watched;
use crate::ui::slider::{Slider, SliderMetrics, Step};
use crate::ui::Ui;
use flaccy_shared::track_revision::{self, copy};
use gtk::glib;
use gtk::prelude::*;
use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

/// Grow/shrink a GridView's column count with its allocated width so natural
/// size stays modest (high max_columns × tile width is what locked the window
/// open before). Starts from whatever max_columns the grid was built with.
pub fn bind_adaptive_grid_columns(grid: &gtk::GridView, tile_width: i32) {
    let tile_width = tile_width.max(96);
    let weak = grid.downgrade();
    crate::ui::resize::watch_width(grid, move |width, _| {
        let Some(grid) = weak.upgrade() else { return };
        let cols = ((width.max(1) as f64) / (tile_width as f64)).floor() as u32;
        let cols = cols.clamp(1, 14);
        if grid.max_columns() != cols {
            grid.set_max_columns(cols);
        }
    });
}

/// The soft top-down color wash behind a detail page's hero, tinted by the
/// cover's dominant color once the artwork lands (store it in `dominant` and
/// queue a redraw). Re-tints when the system switches between light and dark.
pub fn hero_backdrop(dominant: &Rc<RefCell<Option<(u8, u8, u8)>>>) -> gtk::DrawingArea {
    let backdrop = gtk::DrawingArea::new();
    backdrop.set_hexpand(true);
    backdrop.set_vexpand(true);
    {
        let dominant = Rc::clone(dominant);
        backdrop.set_draw_func(move |_, cr, width, height| {
            let Some((r, g, b)) = *dominant.borrow() else {
                return;
            };
            let dark = adw::StyleManager::default().is_dark();
            let blend = |channel: u8| {
                let value = channel as f64 / 255.0;
                if dark {
                    value * 0.55
                } else {
                    value * 0.45 + 0.98 * 0.55
                }
            };
            let (r, g, b) = (blend(r), blend(g), blend(b));
            let gradient = gtk::cairo::LinearGradient::new(0.0, 0.0, 0.0, height as f64);
            gradient.add_color_stop_rgba(0.0, r, g, b, 0.85);
            gradient.add_color_stop_rgba(0.7, r, g, b, 0.0);
            let _ = cr.set_source(&gradient);
            cr.rectangle(0.0, 0.0, width as f64, height as f64);
            let _ = cr.fill();
        });
    }
    {
        let weak = backdrop.downgrade();
        adw::StyleManager::default().connect_dark_notify(move |_| {
            if let Some(backdrop) = weak.upgrade() {
                backdrop.queue_draw();
            }
        });
    }
    backdrop
}

/// Reflects Last.fm love state on a heart button; shared by the mini transport
/// and the full-window player so both stay identical.
pub fn set_love_appearance(button: &gtk::Button, loved: bool) {
    if loved {
        button.add_css_class("loved-heart");
        button.set_tooltip_text(Some("Unlove"));
    } else {
        button.remove_css_class("loved-heart");
        button.set_tooltip_text(Some("Love on Last.fm"));
    }
}

/// Paints a repeat button for the current mode (icon + accent + dimming).
pub fn apply_repeat(repeat: &gtk::Button, mode: RepeatMode) {
    match mode {
        RepeatMode::Off => {
            repeat.set_icon_name("media-playlist-repeat-symbolic");
            repeat.set_opacity(0.5);
            repeat.remove_css_class("accent-toggle");
        }
        RepeatMode::All => {
            repeat.set_icon_name("media-playlist-repeat-symbolic");
            repeat.set_opacity(1.0);
            repeat.add_css_class("accent-toggle");
        }
        RepeatMode::One => {
            repeat.set_icon_name("media-playlist-repeat-song-symbolic");
            repeat.set_opacity(1.0);
            repeat.add_css_class("accent-toggle");
        }
    }
}

/// Turns a metadata label into a click-to-navigate affordance: pointer cursor,
/// hover underline, and a destination tooltip.
pub fn attach_label_nav(
    ui: &Rc<Ui>,
    label: &gtk::Label,
    tooltip: &str,
    go: impl Fn(&Rc<Ui>) + 'static,
) {
    label.add_css_class("nav-link");
    label.set_cursor_from_name(Some("pointer"));
    label.set_tooltip_text(Some(tooltip));
    let click = gtk::GestureClick::new();
    let ui = Rc::clone(ui);
    click.connect_released(move |_, _, _, _| go(&ui));
    label.add_controller(click);
}

pub fn volume_icon_name(volume: f64) -> &'static str {
    if volume <= 0.001 {
        "audio-volume-muted-symbolic"
    } else if volume < 0.34 {
        "audio-volume-low-symbolic"
    } else if volume < 0.67 {
        "audio-volume-medium-symbolic"
    } else {
        "audio-volume-high-symbolic"
    }
}

/// How far an arrow key or wheel notch moves the volume; Page Up/Down move
/// four times as far.
const VOLUME_STEP: f64 = 0.05;

pub struct VolumeControl {
    pub container: gtk::Box,
    /// The slider's percentage readout, for the host to float in an overlay.
    pub bubble: gtk::Label,
}

/// Mute button + capsule slider shared by the bottom transport and the
/// full-window player: the speaker mutes and restores, drags and steps set
/// the level live, and every instance stays in sync through VolumeChanged
/// (external writes like MPRIS and the keyboard shortcuts included).
pub fn build_volume_control(ui: &Rc<Ui>) -> VolumeControl {
    let initial = ui.core.config.borrow().volume;
    let mute = gtk::Button::from_icon_name(volume_icon_name(initial));
    mute.add_css_class("flat");
    mute.add_css_class("volume-mute");
    mute.set_valign(gtk::Align::Center);
    mute.set_tooltip_text(Some(mute_tooltip(initial)));
    {
        let ui = Rc::clone(ui);
        mute.connect_clicked(move |_| ui.core.toggle_mute());
    }

    let slider = Slider::new(SliderMetrics::VOLUME, "Volume");
    slider.area().set_width_request(96);
    slider.set_value(initial);
    slider.set_caption(|fraction| format!("<b>{}</b>", volume_percent(fraction)));
    describe_volume(&slider, initial);
    let apply: Rc<dyn Fn(f64)> = {
        let ui = Rc::clone(ui);
        Rc::new(move |fraction| ui.core.set_volume(whole_percent(fraction)))
    };
    slider.connect_hold({
        let apply = Rc::clone(&apply);
        move |fraction| apply(fraction)
    });
    slider.connect_move({
        let apply = Rc::clone(&apply);
        move |fraction| apply(fraction)
    });
    slider.connect_release(move |fraction| apply(fraction));
    {
        let ui = Rc::clone(ui);
        slider.connect_step(move |step| {
            let current = ui.core.config.borrow().volume;
            let target = match step {
                Step::Fine(steps) => current + steps as f64 * VOLUME_STEP,
                Step::Coarse(steps) => current + steps as f64 * VOLUME_STEP * 4.0,
                Step::To(fraction) => fraction,
            };
            ui.core.set_volume(target);
        });
    }

    let container = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    container.add_css_class("volume-control");
    container.append(&crate::ui::equalizer::capsule_button(ui));
    container.append(&mute);
    container.append(slider.area());
    let bubble = slider.bubble().clone();
    ui.core.hub.subscribe_widget(&container, move |_, event| {
        if let AppEvent::VolumeChanged(value) = event {
            if !slider.is_held() {
                slider.set_value(*value);
            }
            mute.set_icon_name(volume_icon_name(*value));
            mute.set_tooltip_text(Some(mute_tooltip(*value)));
            describe_volume(&slider, *value);
        }
    });
    VolumeControl { container, bubble }
}

/// A pointer lands between pixels; the level it sets is kept to the whole
/// percent the bubble showed.
fn whole_percent(fraction: f64) -> f64 {
    (fraction.clamp(0.0, 1.0) * 100.0).round() / 100.0
}

fn volume_percent(fraction: f64) -> String {
    format!("{}%", (fraction.clamp(0.0, 1.0) * 100.0).round() as i32)
}

fn mute_tooltip(volume: f64) -> &'static str {
    if volume <= 0.001 {
        "Unmute"
    } else {
        "Mute"
    }
}

fn describe_volume(slider: &Slider, volume: f64) {
    slider.set_accessible_value(1.0, volume, &volume_percent(volume));
}

/// The leading cell of a track row: the track number, which gives way to a
/// three-bar equalizer once the player lands on that song. Both live in an
/// overlay so the swap never shifts the columns beside it.
pub struct TrackIndexCell {
    pub widget: gtk::Widget,
    number: gtk::Label,
    indicator: gtk::DrawingArea,
}

/// Builds the leading cell for a track row. `text` is the printed index (an
/// interpunct for tracks without a number, matching the album detail list).
pub fn track_index_cell(text: &str) -> TrackIndexCell {
    let number = gtk::Label::builder()
        .label(text)
        .width_chars(3)
        .xalign(1.0)
        .build();
    number.add_css_class("track-number");

    let indicator = build_equalizer_indicator();
    indicator.set_halign(gtk::Align::End);
    indicator.set_valign(gtk::Align::Center);
    indicator.set_visible(false);

    let slot = gtk::Overlay::new();
    slot.set_child(Some(&number));
    slot.add_overlay(&indicator);
    TrackIndexCell {
        widget: slot.upcast(),
        number,
        indicator,
    }
}

impl TrackIndexCell {
    /// Recovers the cell's parts from a widget built by `track_index_cell`, for
    /// virtualized factories that only keep the widget across row recycling.
    pub fn from_widget(widget: &gtk::Widget) -> Option<TrackIndexCell> {
        let slot = widget.downcast_ref::<gtk::Overlay>()?;
        let number = slot.child().and_downcast::<gtk::Label>()?;
        let indicator = number.next_sibling().and_downcast::<gtk::DrawingArea>()?;
        Some(TrackIndexCell {
            widget: widget.clone(),
            number,
            indicator,
        })
    }

    pub fn set_text(&self, text: &str) {
        self.number.set_label(text);
    }

    /// Swaps the printed index for the equalizer when the player is on this
    /// track, and rests the bars when playback is paused.
    pub fn set_state(&self, current: bool, playing: bool) {
        self.number.set_opacity(if current { 0.0 } else { 1.0 });
        self.indicator.set_visible(current);
        drive_equalizer(&self.indicator, current && playing);
    }
}

impl Clone for TrackIndexCell {
    fn clone(&self) -> Self {
        Self {
            widget: self.widget.clone(),
            number: self.number.clone(),
            indicator: self.indicator.clone(),
        }
    }
}

const EQ_BARS: usize = 3;
/// Seconds per full bounce for each bar. Deliberately co-prime-ish so the trio
/// never falls into lockstep and reads as a level meter rather than a metronome.
const EQ_PERIODS: [f64; EQ_BARS] = [0.62, 0.47, 0.79];
const EQ_RESTING: [f64; EQ_BARS] = [0.34, 0.58, 0.42];

/// Three accent bars that bounce while audio runs. Drawn rather than animated
/// through CSS: GTK only re-measures animated `min-height` sporadically, so the
/// stylesheet version barely moved. One shared metronome redraws every
/// visible, playing indicator, and stops the moment there is none.
pub fn build_equalizer_indicator() -> gtk::DrawingArea {
    let area = gtk::DrawingArea::builder()
        .content_width(15)
        .content_height(14)
        .build();
    area.add_css_class("eq-indicator");
    area.set_draw_func(draw_equalizer);
    area.connect_map(|area| {
        if area.has_css_class(EQ_PLAYING) {
            BARS.with(|bars| bars.join(area));
        }
    });
    area
}

/// Wakes the metronome after the window came back from a suspension, which is
/// the one time registered indicators have no timer behind them.
pub fn resume_bars() {
    BARS.with(Metronome::resume);
}

const EQ_PLAYING: &str = "eq-playing";
/// How often the bars are redrawn. Three small bars bouncing over about half
/// a second read as smooth at this rate, and redrawing them on every vertical
/// blank instead would put a 165 Hz display through a full frame each time.
const EQ_REDRAW: Duration = Duration::from_millis(40);

thread_local! {
    static BARS: Metronome = Metronome::default();
}

/// The one timer behind every bouncing indicator. Indicators that are paused
/// or off screen leave it, and it ends itself when the last one has, so a
/// window with nothing visibly bouncing is not redrawn at all.
#[derive(Default)]
struct Metronome {
    areas: RefCell<Vec<glib::WeakRef<gtk::DrawingArea>>>,
    timer: RefCell<Option<glib::SourceId>>,
}

impl Metronome {
    fn join(&self, area: &gtk::DrawingArea) {
        let mut areas = self.areas.borrow_mut();
        if !areas
            .iter()
            .any(|known| known.upgrade().as_ref() == Some(area))
        {
            areas.push(area.downgrade());
        }
        drop(areas);
        if self.timer.borrow().is_none() {
            let id = glib::timeout_add_local(EQ_REDRAW, || BARS.with(Metronome::beat));
            *self.timer.borrow_mut() = Some(id);
        }
    }

    fn beat(&self) -> glib::ControlFlow {
        let mut areas = self.areas.borrow_mut();
        areas.retain(|weak| {
            weak.upgrade()
                .is_some_and(|area| area.is_mapped() && area.has_css_class(EQ_PLAYING))
        });
        let watched: Vec<gtk::DrawingArea> = areas
            .iter()
            .filter_map(|weak| weak.upgrade())
            .filter(is_watched)
            .collect();
        for area in &watched {
            area.queue_draw();
        }
        if watched.is_empty() {
            drop(areas);
            self.timer.borrow_mut().take();
            return glib::ControlFlow::Break;
        }
        glib::ControlFlow::Continue
    }

    /// Starts the timer again for indicators that stayed registered through a
    /// suspension.
    fn resume(&self) {
        if self.areas.borrow().is_empty() || self.timer.borrow().is_some() {
            return;
        }
        let id = glib::timeout_add_local(EQ_REDRAW, || BARS.with(Metronome::beat));
        *self.timer.borrow_mut() = Some(id);
    }
}

fn draw_equalizer(area: &gtk::DrawingArea, cr: &gtk::cairo::Context, width: i32, height: i32) {
    let color = area.color();
    cr.set_source_rgba(
        color.red() as f64,
        color.green() as f64,
        color.blue() as f64,
        color.alpha() as f64,
    );
    let seconds = area
        .frame_clock()
        .map(|clock| clock.frame_time() as f64 / 1_000_000.0)
        .unwrap_or(0.0);
    let animated = area.has_css_class(EQ_PLAYING) && animations_enabled();
    let gap = 2.0;
    let bar_width = ((width as f64 - gap * (EQ_BARS as f64 - 1.0)) / EQ_BARS as f64).max(1.0);
    let floor = 3.0_f64.min(height as f64);
    for index in 0..EQ_BARS {
        let level = if animated {
            let phase = seconds / EQ_PERIODS[index] * std::f64::consts::TAU;
            0.5 + 0.5 * phase.sin()
        } else {
            EQ_RESTING[index]
        };
        let bar_height = floor + (height as f64 - floor) * level;
        let x = index as f64 * (bar_width + gap);
        rounded_bar(cr, x, height as f64 - bar_height, bar_width, bar_height);
    }
    let _ = cr.fill();
}

fn rounded_bar(cr: &gtk::cairo::Context, x: f64, y: f64, width: f64, height: f64) {
    let radius = (width / 2.0).min(height / 2.0);
    let (right, bottom) = (x + width, y + height);
    let half_pi = std::f64::consts::FRAC_PI_2;
    cr.new_sub_path();
    cr.arc(right - radius, y + radius, radius, -half_pi, 0.0);
    cr.arc(right - radius, bottom - radius, radius, 0.0, half_pi);
    cr.arc(
        x + radius,
        bottom - radius,
        radius,
        half_pi,
        std::f64::consts::PI,
    );
    cr.arc(
        x + radius,
        y + radius,
        radius,
        std::f64::consts::PI,
        3.0 * half_pi,
    );
    cr.close_path();
}

/// Honors the desktop's "reduce animation" preference, so the indicator settles
/// into a static silhouette instead of bouncing forever.
fn animations_enabled() -> bool {
    gtk::Settings::default().is_none_or(|settings| settings.is_gtk_enable_animations())
}

/// Starts or stops the bars. Keyed off the `eq-playing` class so it is
/// idempotent: re-arming a running indicator is a no-op, and clearing the class
/// drops it from the metronome on its next beat.
pub fn drive_equalizer(area: &gtk::DrawingArea, playing: bool) {
    if !playing {
        area.remove_css_class(EQ_PLAYING);
        area.set_tooltip_text(Some("Paused"));
        area.queue_draw();
        return;
    }
    area.set_tooltip_text(Some("Now playing"));
    if area.has_css_class(EQ_PLAYING) {
        return;
    }
    area.add_css_class(EQ_PLAYING);
    if area.is_mapped() {
        BARS.with(|bars| bars.join(area));
    }
}

/// Lights a track row up while the player is on it: an accent wash across the
/// row, an accent-tinted title, and the equalizer replacing the track number.
/// Stays live, so a row built while something else plays reacts the moment its
/// song comes round.
pub fn attach_now_playing_row(
    ui: &Rc<Ui>,
    row: &gtk::ListBoxRow,
    cell: &TrackIndexCell,
    title: &gtk::Label,
    rel_path: String,
) {
    let apply = {
        let row = row.clone();
        let cell = cell.clone();
        let title = title.clone();
        move |current: bool, playing: bool| {
            if current {
                row.add_css_class("now-playing-row");
                title.add_css_class("now-playing-title");
            } else {
                row.remove_css_class("now-playing-row");
                title.remove_css_class("now-playing-title");
            }
            let described = match (current, playing) {
                (true, true) => "Now playing",
                (true, false) => "Paused",
                _ => "",
            };
            row.update_property(&[gtk::accessible::Property::Description(described)]);
            cell.set_state(current, playing);
        }
    };
    apply(
        ui.core
            .player
            .current_track()
            .is_some_and(|track| track.rel_path == rel_path),
        ui.core.player.is_playing(),
    );

    let ui_ref = Rc::clone(ui);
    ui.core
        .hub
        .subscribe_widget(row, move |_, event| match event {
            AppEvent::TrackChanged(track) => apply(
                track
                    .as_ref()
                    .is_some_and(|track| track.rel_path == rel_path),
                ui_ref.core.player.is_playing(),
            ),
            AppEvent::PlayingChanged(playing) => apply(
                ui_ref
                    .core
                    .player
                    .current_track()
                    .is_some_and(|track| track.rel_path == rel_path),
                *playing,
            ),
            _ => {}
        });
}

/// Feeds the now-playing dominant color to the theme engine; a no-op unless the
/// Adaptive theme is active, where it retints the whole app.
pub fn set_adaptive_accent(color: Option<(u8, u8, u8)>) {
    if let Some(controller) = crate::theme::ThemeController::current() {
        controller.set_artwork_color(color);
    }
}

/// The pill beside a title while the song's latest re-export is recent. Hidden
/// until a caller decides the song earns it.
pub fn new_mix_chip() -> gtk::Label {
    let chip = gtk::Label::new(Some(copy::NEW_MIX));
    chip.add_css_class("new-mix-chip");
    chip.set_valign(gtk::Align::Center);
    chip.set_visible(false);
    chip
}

/// Whether the song's latest re-export is recent enough to be called a new mix.
pub fn shows_new_mix(track: &Track) -> bool {
    track_revision::shows_new_mix(track.revised_at, crate::db::now_ms())
}

/// A chip that follows the library: it reads the song's row again every time
/// the library reloads, so a scan that recognises a re-export lights it on a
/// page that was built before.
pub fn live_new_mix_chip(ui: &Rc<Ui>, track: &Track) -> gtk::Label {
    let chip = new_mix_chip();
    chip.set_visible(shows_new_mix(track));
    follow_library(ui, &chip, track.rel_path.clone());
    chip
}

/// Re-evaluates `chip` for `rel_path` on every library reload.
fn follow_library(ui: &Rc<Ui>, chip: &gtk::Label, rel_path: String) {
    let hub = Rc::clone(&ui.core.hub);
    let ui = Rc::clone(ui);
    hub.subscribe_widget(chip, move |chip, event| {
        if !matches!(event, AppEvent::LibraryReloaded) {
            return;
        }
        let visible = ui
            .core
            .library
            .borrow()
            .track_by_rel_path(&rel_path)
            .is_some_and(shows_new_mix);
        chip.set_visible(visible);
    });
}
