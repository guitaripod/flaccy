use crate::app::AppCore;
use flaccy_shared::track_revision::copy;
use gtk::gdk;
use gtk::gio;
use gtk::glib;
use gtk::prelude::*;
use std::rc::Rc;

/// Menus render through `popup_menu_at`'s plain-widget popover (GtkPopoverMenu
/// on GTK 4.22 under-allocates multi-section models and clips trailing rows),
/// so section count is not constrained.
pub fn track_menu(rel_path: &str, loved: bool, has_previous: bool) -> gio::Menu {
    let remote = crate::remote::is_remote(rel_path);
    let menu = gio::Menu::new();
    let queue_section = gio::Menu::new();
    queue_section.append_item(&item("Play Next", "win.track-play-next", rel_path));
    queue_section.append_item(&item("Add to Queue", "win.track-queue", rel_path));
    menu.append_section(None, &queue_section);

    let nav_section = gio::Menu::new();
    nav_section.append_item(&item("Go to Album", "win.track-go-album", rel_path));
    nav_section.append_item(&item("Go to Artist", "win.track-go-artist", rel_path));
    menu.append_section(None, &nav_section);

    let station_section = gio::Menu::new();
    station_section.append_item(&item("Start Station", "win.track-station", rel_path));
    menu.append_section(None, &station_section);

    let actions_section = gio::Menu::new();
    let love_label = if loved { "Unlove" } else { "Love on Last.fm" };
    actions_section.append_item(&item(love_label, "win.track-love", rel_path));
    actions_section.append_item(&item("Add to Playlist…", "win.playlist-choose", rel_path));
    actions_section.append_item(&item("Share Songlink…", "win.track-share", rel_path));
    actions_section.append_item(&item("Copy Songlink", "win.track-songlink", rel_path));
    if remote {
        let kept = crate::remote::is_pinned(rel_path);
        let (label, action) = download_entry(kept, "win.track-unpin", "win.track-pin");
        actions_section.append_item(&item(label, action, rel_path));
    } else {
        actions_section.append_item(&item("Show in Files", "win.track-reveal", rel_path));
    }
    if has_previous {
        actions_section.append_item(&item(
            copy::RESTORE_PREVIOUS,
            "win.track-restore",
            rel_path,
        ));
    }
    menu.append_section(None, &actions_section);

    if !remote {
        let delete_section = gio::Menu::new();
        delete_section.append_item(&item("Move to Trash…", "win.track-delete", rel_path));
        menu.append_section(None, &delete_section);
    }
    menu
}

/// The label and action of a menu's Download entry: it keeps the songs, or when
/// they are all kept already, removes the download.
pub fn download_entry<'a>(
    kept: bool,
    remove_action: &'a str,
    keep_action: &'a str,
) -> (&'static str, &'a str) {
    if kept {
        ("Remove Download", remove_action)
    } else {
        ("Download", keep_action)
    }
}

/// What an album's Download entry offers, from the songs the library holds for
/// it; see `crate::remote::downloads_state`.
pub fn album_downloads(core: &AppCore, key: &str) -> Option<bool> {
    let library = core.library.borrow().clone();
    let album = library.album_by_key(key)?;
    crate::remote::downloads_state(album.tracks.iter().map(|track| track.rel_path.as_str()))
}

/// What a playlist's Download entry offers, from the songs it holds.
pub fn playlist_downloads(core: &AppCore, playlist_id: i64) -> Option<bool> {
    let rows = core.db.playlist_tracks(playlist_id);
    crate::remote::downloads_state(rows.iter().map(|row| row.rel_path.as_str()))
}

pub fn album_menu(key: &str, downloads: Option<bool>) -> gio::Menu {
    let menu = gio::Menu::new();
    let play_section = gio::Menu::new();
    play_section.append_item(&item("Play", "win.play-album", key));
    play_section.append_item(&item("Shuffle", "win.shuffle-album", key));
    menu.append_section(None, &play_section);
    let queue_section = gio::Menu::new();
    queue_section.append_item(&item("Play Next", "win.album-play-next", key));
    queue_section.append_item(&item("Add to Queue", "win.album-queue", key));
    menu.append_section(None, &queue_section);
    let nav_section = gio::Menu::new();
    nav_section.append_item(&item("Go to Artist", "win.album-go-artist", key));
    menu.append_section(None, &nav_section);
    let extra_section = gio::Menu::new();
    extra_section.append_item(&item("Start Station", "win.album-station", key));
    extra_section.append_item(&item("Share Songlink…", "win.album-share", key));
    extra_section.append_item(&item("Copy Songlink", "win.album-songlink", key));
    extra_section.append_item(&item("Edit Artwork…", "win.album-artwork", key));
    extra_section.append_item(&item("Enrich Metadata", "win.album-enrich", key));
    if let Some(kept) = downloads {
        let (label, action) = download_entry(kept, "win.album-unpin", "win.album-pin");
        extra_section.append_item(&item(label, action, key));
    }
    extra_section.append_item(&item("Show in Files", "win.album-reveal", key));
    menu.append_section(None, &extra_section);

    let delete_section = gio::Menu::new();
    delete_section.append_item(&item("Move to Trash…", "win.album-delete", key));
    menu.append_section(None, &delete_section);
    menu
}

pub fn artist_menu(artist: &str) -> gio::Menu {
    let menu = gio::Menu::new();
    let play_section = gio::Menu::new();
    play_section.append_item(&item("Play", "win.artist-play", artist));
    play_section.append_item(&item("Shuffle", "win.artist-shuffle", artist));
    menu.append_section(None, &play_section);
    let queue_section = gio::Menu::new();
    queue_section.append_item(&item("Play Next", "win.artist-play-next", artist));
    queue_section.append_item(&item("Add to Queue", "win.artist-queue", artist));
    menu.append_section(None, &queue_section);
    let station_section = gio::Menu::new();
    station_section.append_item(&item("Start Station", "win.artist-station", artist));
    menu.append_section(None, &station_section);
    let nav_section = gio::Menu::new();
    nav_section.append_item(&item("Go to Artist", "win.artist-go", artist));
    menu.append_section(None, &nav_section);
    menu
}

fn item(label: &str, action: &str, target: &str) -> gio::MenuItem {
    let entry = gio::MenuItem::new(Some(label), None);
    entry.set_action_and_target_value(Some(action), Some(&target.to_variant()));
    entry
}

/// Renders the menu model with plain widgets in a gtk::Popover instead of
/// GtkPopoverMenu: GTK 4.22's PopoverMenu under-allocates multi-section models
/// and silently clips the trailing rows (reproduced with a minimal PyGObject
/// app on this GTK, so not a flaccy regression).
pub fn popup_menu_at(parent: &impl IsA<gtk::Widget>, menu: &gio::Menu, x: f64, y: f64) {
    let popover = gtk::Popover::builder()
        .has_arrow(false)
        .autohide(true)
        .build();
    popover.add_css_class("menu");
    popover.set_parent(parent);
    popover.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));

    let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let mut first = true;
    for section in 0..menu.n_items() {
        let items: gio::MenuModel = match menu.item_link(section, gio::MENU_LINK_SECTION) {
            Some(model) => model,
            None => menu.clone().upcast(),
        };
        let in_section = menu.item_link(section, gio::MENU_LINK_SECTION).is_some();
        if in_section {
            if !first {
                let separator = gtk::Separator::new(gtk::Orientation::Horizontal);
                separator.set_margin_top(4);
                separator.set_margin_bottom(4);
                content.append(&separator);
            }
            for index in 0..items.n_items() {
                append_menu_row(&content, &items, index, &popover);
            }
            first = false;
        } else {
            append_menu_row(&content, &items, section, &popover);
            first = false;
        }
    }

    popover.set_child(Some(&content));
    popover.connect_closed(|popover| {
        let popover = popover.clone();
        glib::idle_add_local_once(move || popover.unparent());
    });
    popover.popup();
}

fn append_menu_row(content: &gtk::Box, items: &gio::MenuModel, index: i32, popover: &gtk::Popover) {
    let Some(label) = items.item_attribute_value(index, "label", Some(glib::VariantTy::STRING))
    else {
        return;
    };
    let Some(action) = items.item_attribute_value(index, "action", Some(glib::VariantTy::STRING))
    else {
        return;
    };
    let target = items.item_attribute_value(index, "target", None);
    let button = gtk::Button::builder()
        .child(
            &gtk::Label::builder()
                .label(label.str().unwrap_or_default())
                .xalign(0.0)
                .build(),
        )
        .build();
    button.add_css_class("flat");
    button.add_css_class("context-menu-item");
    let popover = popover.clone();
    let action_name = action.str().unwrap_or_default().to_string();
    button.connect_clicked(move |button| {
        popover.popdown();
        let _ = gtk::prelude::WidgetExt::activate_action(button, &action_name, target.as_ref());
    });
    content.append(&button);
}

pub fn attach_track_context_menu(
    widget: &impl IsA<gtk::Widget>,
    core: &Rc<AppCore>,
    rel_path: String,
) {
    let gesture = gtk::GestureClick::builder()
        .button(gdk::BUTTON_SECONDARY)
        .build();
    let core = Rc::clone(core);
    let target = widget.clone().upcast::<gtk::Widget>();
    gesture.connect_pressed(move |_, _, x, y| {
        let loved = core
            .library
            .borrow()
            .track_by_rel_path(&rel_path)
            .map(|t| t.loved)
            .unwrap_or(false);
        let menu = track_menu(&rel_path, loved, core.has_previous_version(&rel_path));
        popup_menu_at(&target, &menu, x, y);
    });
    widget.add_controller(gesture);
}

pub fn attach_artist_context_menu(widget: &impl IsA<gtk::Widget>, artist: String) {
    let gesture = gtk::GestureClick::builder()
        .button(gdk::BUTTON_SECONDARY)
        .build();
    let target = widget.clone().upcast::<gtk::Widget>();
    gesture.connect_pressed(move |_, _, x, y| {
        let menu = artist_menu(&artist);
        popup_menu_at(&target, &menu, x, y);
    });
    widget.add_controller(gesture);
}

/// Right-click on a Jump Back In row offers to take it off the shelf.
pub fn attach_jump_back_in_menu(widget: &impl IsA<gtk::Widget>, key: String) {
    let gesture = gtk::GestureClick::builder()
        .button(gdk::BUTTON_SECONDARY)
        .build();
    let target = widget.clone().upcast::<gtk::Widget>();
    gesture.connect_pressed(move |_, _, x, y| {
        let menu = gio::Menu::new();
        menu.append_item(&item(
            flaccy_shared::home_copy::REMOVE_FROM_JUMP_BACK_IN,
            "win.home-jump-remove",
            &key,
        ));
        popup_menu_at(&target, &menu, x, y);
    });
    widget.add_controller(gesture);
}

pub fn attach_album_context_menu(widget: &impl IsA<gtk::Widget>, core: &Rc<AppCore>, key: String) {
    let core = Rc::clone(core);
    let gesture = gtk::GestureClick::builder()
        .button(gdk::BUTTON_SECONDARY)
        .build();
    let target = widget.clone().upcast::<gtk::Widget>();
    gesture.connect_pressed(move |_, _, x, y| {
        let menu = album_menu(&key, album_downloads(&core, &key));
        popup_menu_at(&target, &menu, x, y);
    });
    widget.add_controller(gesture);
}
