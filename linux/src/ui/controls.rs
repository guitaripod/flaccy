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

/// Feeds the now-playing dominant color to the theme engine; a no-op unless the
/// Adaptive theme is active, where it retints the whole app.
pub fn set_adaptive_accent(color: Option<(u8, u8, u8)>) {
    if let Some(controller) = crate::theme::ThemeController::current() {
        controller.set_artwork_color(color);
    }
}
