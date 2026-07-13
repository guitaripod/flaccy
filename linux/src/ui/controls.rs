use crate::player::RepeatMode;
use gtk::prelude::*;

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
