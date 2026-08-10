use crate::config;
use gtk::gdk;
use std::cell::RefCell;

thread_local! {
    static PROVIDER: RefCell<Option<gtk::CssProvider>> = const { RefCell::new(None) };
    static LAST_CSS: RefCell<String> = const { RefCell::new(String::new()) };
}

/// Lyrics typography lives in its own swappable provider rather than in
/// `ThemeController`, so resizing the type never forces a whole-app palette
/// recompute. It sits above both the base stylesheet and the theme provider.
pub fn apply(size: i32) {
    let size = size.clamp(config::LYRICS_FONT_MIN, config::LYRICS_FONT_MAX);
    let css = format!(
        ".lyric-line, .lyric-line-near, .lyric-line-current {{ font-size: {size}px; }}\n\
         .lyric-line-current {{ font-size: {current}px; }}\n\
         .lyrics-spacer {{ min-height: {spacer}px; }}\n",
        size = size,
        current = size,
        spacer = size * 6,
    );
    if LAST_CSS.with(|last| *last.borrow() == css) {
        return;
    }
    LAST_CSS.with(|last| *last.borrow_mut() = css.clone());
    PROVIDER.with(|slot| {
        let mut slot = slot.borrow_mut();
        let provider = slot.get_or_insert_with(|| {
            let provider = gtk::CssProvider::new();
            if let Some(display) = gdk::Display::default() {
                gtk::style_context_add_provider_for_display(
                    &display,
                    &provider,
                    gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 2,
                );
            }
            provider
        });
        provider.load_from_string(&css);
    });
}
