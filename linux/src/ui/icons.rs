//! Flaccy draws every glyph from its own `flaccy-*-symbolic` set
//! (`data/icons`, built from Phosphor), so the app looks the same under any
//! desktop icon theme. Widgets GTK and libadwaita build themselves (window
//! buttons, the magnifier in a search field, a row's chevron) still name
//! icons from the desktop's theme; `adopt` swaps those for Flaccy's own.

use gtk::prelude::*;

/// The Flaccy glyph that stands in for an icon a toolkit widget asked the
/// desktop's theme for.
fn own_name(theme_name: &str) -> Option<&'static str> {
    let own = match theme_name {
        "window-minimize-symbolic" => "flaccy-window-minimize-symbolic",
        "window-maximize-symbolic" => "flaccy-window-maximize-symbolic",
        "window-restore-symbolic" => "flaccy-window-restore-symbolic",
        "window-close-symbolic" => "flaccy-close-symbolic",
        "edit-find-symbolic" | "system-search-symbolic" => "flaccy-search-symbolic",
        "edit-clear-symbolic" => "flaccy-close-symbolic",
        "go-next-symbolic" => "flaccy-chevron-right-symbolic",
        "go-previous-symbolic" => "flaccy-chevron-left-symbolic",
        "pan-down-symbolic" => "flaccy-chevron-down-symbolic",
        "pan-up-symbolic" => "flaccy-chevron-up-symbolic",
        "pan-end-symbolic" => "flaccy-chevron-right-symbolic",
        "pan-start-symbolic" => "flaccy-chevron-left-symbolic",
        "list-add-symbolic" | "value-increase-symbolic" => "flaccy-add-symbolic",
        "list-remove-symbolic" | "value-decrease-symbolic" => "flaccy-remove-symbolic",
        "document-edit-symbolic" => "flaccy-edit-symbolic",
        "object-select-symbolic" => "flaccy-check-symbolic",
        "open-menu-symbolic" => "flaccy-menu-symbolic",
        "view-more-symbolic" => "flaccy-more-symbolic",
        _ => return None,
    };
    Some(own)
}

/// Swaps every desktop-theme icon under `root` for Flaccy's own.
pub fn adopt(root: &impl IsA<gtk::Widget>) {
    let root = root.as_ref();
    if let Some(image) = root.downcast_ref::<gtk::Image>() {
        if let Some(own) = image.icon_name().as_deref().and_then(own_name) {
            image.set_icon_name(Some(own));
        }
    }
    let mut child = root.first_child();
    while let Some(widget) = child {
        adopt(&widget);
        child = widget.next_sibling();
    }
}

/// Keeps `root` in Flaccy's glyphs for as long as it lives: once when it is
/// first shown, and again whenever it is shown anew, since toolkit widgets
/// rebuild their own buttons.
pub fn keep_adopted(root: &impl IsA<gtk::Widget>) {
    let root = root.as_ref();
    root.connect_map(|root| adopt(root));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn toolkit_icons_map_to_bundled_glyphs() {
        assert_eq!(own_name("window-close-symbolic"), Some("flaccy-close-symbolic"));
        assert_eq!(own_name("edit-find-symbolic"), Some("flaccy-search-symbolic"));
        assert_eq!(own_name("flaccy-play-symbolic"), None);
        assert_eq!(own_name("folder-symbolic"), None);
    }
}
