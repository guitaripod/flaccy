use crate::player::RepeatMode;
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

/// Feeds the now-playing dominant color to the theme engine; a no-op unless the
/// Adaptive theme is active, where it retints the whole app.
pub fn set_adaptive_accent(color: Option<(u8, u8, u8)>) {
    if let Some(controller) = crate::theme::ThemeController::current() {
        controller.set_artwork_color(color);
    }
}
