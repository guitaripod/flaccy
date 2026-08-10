use crate::events::AppEvent;
use crate::player::RepeatMode;
use crate::ui::Ui;
use gtk::glib;
use gtk::prelude::*;
use std::cell::Cell;
use std::rc::Rc;

/// Grow/shrink a GridView's column count with its allocated width so natural
/// size stays modest (high max_columns × tile width is what locked the window
/// open before). Starts from whatever max_columns the grid was built with.
pub fn bind_adaptive_grid_columns(grid: &gtk::GridView, tile_width: i32) {
    let tile_width = tile_width.max(96);
    let last_width = Rc::new(Cell::new(0i32));
    grid.connect_realize(move |grid| {
        let last_width = Rc::clone(&last_width);
        grid.add_tick_callback(move |grid, _| {
            let width = grid.width();
            if width <= 1 || width == last_width.get() {
                return glib::ControlFlow::Continue;
            }
            last_width.set(width);
            let cols = ((width.max(1) as f64) / (tile_width as f64)).floor() as u32;
            let cols = cols.clamp(1, 14);
            if grid.max_columns() != cols {
                grid.set_max_columns(cols);
            }
            glib::ControlFlow::Continue
        });
    });
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

pub struct VolumeControl {
    pub container: gtk::Box,
}

/// Icon + slider volume cluster shared by the bottom transport and the
/// full-window player: drags and scroll steps drive the player volume, the
/// icon tracks the level, and every instance stays in sync through
/// VolumeChanged (external writes like MPRIS included).
pub fn build_volume_control(ui: &Rc<Ui>) -> VolumeControl {
    let initial = ui.core.config.borrow().volume;
    let icon = gtk::Image::from_icon_name(volume_icon_name(initial));
    icon.add_css_class("dim");
    icon.add_css_class("transport-volume-icon");
    let scale = gtk::Scale::with_range(gtk::Orientation::Horizontal, 0.0, 1.0, 0.02);
    scale.set_tooltip_text(Some("Volume (scroll to adjust)"));
    scale.set_width_request(88);
    scale.set_draw_value(false);
    scale.add_css_class("transport-volume");
    scale.set_value(initial);

    let syncing = Rc::new(Cell::new(false));
    {
        let ui = Rc::clone(ui);
        let syncing = Rc::clone(&syncing);
        let icon = icon.clone();
        scale.connect_value_changed(move |scale| {
            icon.set_icon_name(Some(volume_icon_name(scale.value())));
            if !syncing.get() {
                ui.core.set_volume(scale.value());
            }
        });
    }
    {
        let scroll = gtk::EventControllerScroll::new(
            gtk::EventControllerScrollFlags::VERTICAL | gtk::EventControllerScrollFlags::DISCRETE,
        );
        let scale_ref = scale.clone();
        scroll.connect_scroll(move |_, _, dy| {
            let next = (scale_ref.value() - dy * 0.05).clamp(0.0, 1.0);
            scale_ref.set_value(next);
            glib::Propagation::Stop
        });
        scale.add_controller(scroll);
    }

    let container = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    container.append(&icon);
    container.append(&scale);
    {
        let scale = scale.clone();
        ui.core.hub.subscribe_widget(&container, move |_, event| {
            if let AppEvent::VolumeChanged(value) = event {
                if (scale.value() - value).abs() > 0.001 {
                    syncing.set(true);
                    scale.set_value(*value);
                    syncing.set(false);
                }
            }
        });
    }
    VolumeControl { container }
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
    TrackIndexCell { widget: slot.upcast(), number, indicator }
}

impl TrackIndexCell {
    /// Recovers the cell's parts from a widget built by `track_index_cell`, for
    /// virtualized factories that only keep the widget across row recycling.
    pub fn from_widget(widget: &gtk::Widget) -> Option<TrackIndexCell> {
        let slot = widget.downcast_ref::<gtk::Overlay>()?;
        let number = slot.child().and_downcast::<gtk::Label>()?;
        let indicator = number.next_sibling().and_downcast::<gtk::DrawingArea>()?;
        Some(TrackIndexCell { widget: widget.clone(), number, indicator })
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
/// stylesheet version barely moved. The frame clock drives the phase, and the
/// callback tears itself down the moment playback stops so idle rows cost
/// nothing.
pub fn build_equalizer_indicator() -> gtk::DrawingArea {
    let area = gtk::DrawingArea::builder()
        .content_width(15)
        .content_height(14)
        .build();
    area.add_css_class("eq-indicator");
    area.set_draw_func(draw_equalizer);
    area
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
    let animated = area.has_css_class("eq-playing") && animations_enabled();
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
    cr.arc(x + radius, bottom - radius, radius, half_pi, std::f64::consts::PI);
    cr.arc(x + radius, y + radius, radius, std::f64::consts::PI, 3.0 * half_pi);
    cr.close_path();
}

/// Honors the desktop's "reduce animation" preference, so the indicator settles
/// into a static silhouette instead of bouncing forever.
fn animations_enabled() -> bool {
    gtk::Settings::default().is_none_or(|settings| settings.is_gtk_enable_animations())
}

/// Starts or stops the bars. Keyed off the `eq-playing` class so it is
/// idempotent: re-arming a running indicator is a no-op, and clearing the class
/// ends the frame callback on its next tick.
pub fn drive_equalizer(area: &gtk::DrawingArea, playing: bool) {
    if !playing {
        area.remove_css_class("eq-playing");
        area.set_tooltip_text(Some("Paused"));
        area.queue_draw();
        return;
    }
    area.set_tooltip_text(Some("Now playing"));
    if area.has_css_class("eq-playing") {
        return;
    }
    area.add_css_class("eq-playing");
    area.add_tick_callback(|area, _| {
        area.queue_draw();
        if area.has_css_class("eq-playing") {
            glib::ControlFlow::Continue
        } else {
            glib::ControlFlow::Break
        }
    });
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
    ui.core.hub.subscribe_widget(row, move |_, event| match event {
        AppEvent::TrackChanged(track) => apply(
            track.as_ref().is_some_and(|track| track.rel_path == rel_path),
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
