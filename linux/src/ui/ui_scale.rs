use crate::config;
use gtk::gdk;
use std::cell::{Cell, RefCell};

thread_local! {
    static CURRENT: Cell<f64> = const { Cell::new(config::UI_SCALE_DEFAULT) };
    static BASE_PROVIDER: RefCell<Option<gtk::CssProvider>> = const { RefCell::new(None) };
}

const BASE_CSS: &str = include_str!("style.css");
const BASE_DPI: f64 = 96.0;

/// The zoom every other scaling surface reads: `lyrics_style` multiplies its
/// pixel sizes by it and the Preferences spinner mirrors it.
pub fn current() -> f64 {
    CURRENT.with(|c| c.get())
}

pub fn percent(scale: f64) -> i32 {
    (scale * 100.0).round() as i32
}

/// Applies a whole-interface zoom. Two things move together: the GTK font
/// DPI, which scales every point-sized run of text plus everything measured in
/// `em`, and the app stylesheet, whose pixel font sizes are rewritten by the
/// same factor before the provider reloads. Both are live — no relaunch.
pub fn apply(scale: f64) {
    let scale = config::clamp_ui_scale(scale.clamp(config::UI_SCALE_MIN, config::UI_SCALE_MAX));
    CURRENT.with(|c| c.set(scale));
    if let Some(settings) = gtk::Settings::default() {
        settings.set_gtk_xft_dpi((BASE_DPI * 1024.0 * scale).round() as i32);
    }
    BASE_PROVIDER.with(|slot| {
        let mut slot = slot.borrow_mut();
        let provider = slot.get_or_insert_with(|| {
            let provider = gtk::CssProvider::new();
            if let Some(display) = gdk::Display::default() {
                gtk::style_context_add_provider_for_display(
                    &display,
                    &provider,
                    gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
                );
            }
            provider
        });
        provider.load_from_string(&format!(
            "{}\n{}",
            scaled_stylesheet(BASE_CSS, scale),
            icon_rule(scale)
        ));
    });
    crate::ui::lyrics_style::reapply();
}

/// Symbolic icons are drawn at GTK's 16 px default regardless of font DPI, so
/// they grow with the same factor; artwork and anything with an explicit
/// pixel size keeps its own measure.
fn icon_rule(scale: f64) -> String {
    if (scale - 1.0).abs() < f64::EPSILON {
        return String::new();
    }
    let size = (16.0 * scale).round();
    format!("image.normal-icons, button > image, .flat > image {{ -gtk-icon-size: {size}px; }}")
}

/// Rewrites every `font-size: <n>px` declaration by `scale`, leaving spacing,
/// radii and icon sizes alone so the chrome keeps its proportions.
fn scaled_stylesheet(css: &str, scale: f64) -> String {
    if (scale - 1.0).abs() < f64::EPSILON {
        return css.to_string();
    }
    let mut out = String::with_capacity(css.len() + 64);
    let mut rest = css;
    const KEY: &str = "font-size:";
    while let Some(at) = rest.find(KEY) {
        let (head, tail) = rest.split_at(at + KEY.len());
        out.push_str(head);
        let value = tail.trim_start();
        let digits: String = value
            .chars()
            .take_while(|c| c.is_ascii_digit() || *c == '.')
            .collect();
        let after = &value[digits.len()..];
        match digits.parse::<f64>() {
            Ok(px) if after.starts_with("px") => {
                let scaled = (px * scale * 10.0).round() / 10.0;
                out.push_str(&format!(" {scaled}px"));
                rest = &after[2..];
            }
            _ => rest = tail,
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scales_pixel_font_sizes_only() {
        let css = ".a { font-size: 11px; padding: 4px; }\n.b { font-size: 1.2em; }";
        let scaled = scaled_stylesheet(css, 1.5);
        assert_eq!(
            scaled,
            ".a { font-size: 16.5px; padding: 4px; }\n.b { font-size: 1.2em; }"
        );
        assert_eq!(scaled_stylesheet(css, 1.0), css);
    }

    #[test]
    fn steps_snap_to_the_grid() {
        assert_eq!(config::clamp_ui_scale(1.0 + 0.1 + 0.1 + 0.1), 1.3);
        assert_eq!(config::clamp_ui_scale(0.7499), 0.7);
    }
}
