use crate::app::AppCore;
use gtk::gdk;
use gtk::gio;
use gtk::glib;
use gtk::prelude::*;
use std::rc::Rc;

pub fn track_menu(core: &Rc<AppCore>, rel_path: &str, loved: bool) -> gio::Menu {
    let menu = gio::Menu::new();
    let queue_section = gio::Menu::new();
    queue_section.append_item(&item("Play Next", "win.track-play-next", rel_path));
    queue_section.append_item(&item("Add to Queue", "win.track-queue", rel_path));
    menu.append_section(None, &queue_section);

    let station_section = gio::Menu::new();
    station_section.append_item(&item("Start Station", "win.track-station", rel_path));
    menu.append_section(None, &station_section);

    let love_section = gio::Menu::new();
    let love_label = if loved { "Unlove" } else { "Love on Last.fm" };
    love_section.append_item(&item(love_label, "win.track-love", rel_path));
    menu.append_section(None, &love_section);

    let playlist_menu = gio::Menu::new();
    for playlist in core.db.fetch_playlists() {
        let entry = gio::MenuItem::new(Some(&playlist.name), None);
        entry.set_action_and_target_value(
            Some("win.playlist-add"),
            Some(&(playlist.id, rel_path.to_string()).to_variant()),
        );
        playlist_menu.append_item(&entry);
    }
    playlist_menu.append_item(&item("New Playlist…", "win.playlist-new-with-track", rel_path));
    menu.append_submenu(Some("Add to Playlist"), &playlist_menu);

    let share_section = gio::Menu::new();
    share_section.append_item(&item("Copy song.link", "win.track-songlink", rel_path));
    menu.append_section(None, &share_section);
    menu
}

pub fn album_menu(key: &str) -> gio::Menu {
    let menu = gio::Menu::new();
    let play_section = gio::Menu::new();
    play_section.append_item(&item("Play", "win.play-album", key));
    play_section.append_item(&item("Shuffle", "win.shuffle-album", key));
    menu.append_section(None, &play_section);
    let queue_section = gio::Menu::new();
    queue_section.append_item(&item("Play Next", "win.album-play-next", key));
    queue_section.append_item(&item("Add to Queue", "win.album-queue", key));
    menu.append_section(None, &queue_section);
    let extra_section = gio::Menu::new();
    extra_section.append_item(&item("Start Station", "win.album-station", key));
    extra_section.append_item(&item("Copy song.link", "win.album-songlink", key));
    menu.append_section(None, &extra_section);
    menu
}

fn item(label: &str, action: &str, target: &str) -> gio::MenuItem {
    let entry = gio::MenuItem::new(Some(label), None);
    entry.set_action_and_target_value(Some(action), Some(&target.to_variant()));
    entry
}

pub fn popup_menu_at(parent: &impl IsA<gtk::Widget>, menu: &gio::Menu, x: f64, y: f64) {
    let popover = gtk::PopoverMenu::from_model(Some(menu));
    popover.set_parent(parent);
    popover.set_has_arrow(false);
    popover.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
    popover.connect_closed(|popover| {
        let popover = popover.clone();
        glib::idle_add_local_once(move || popover.unparent());
    });
    popover.popup();
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
        let menu = track_menu(&core, &rel_path, loved);
        popup_menu_at(&target, &menu, x, y);
    });
    widget.add_controller(gesture);
}

pub fn attach_album_context_menu(widget: &impl IsA<gtk::Widget>, key: String) {
    let gesture = gtk::GestureClick::builder()
        .button(gdk::BUTTON_SECONDARY)
        .build();
    let target = widget.clone().upcast::<gtk::Widget>();
    gesture.connect_pressed(move |_, _, x, y| {
        let menu = album_menu(&key);
        popup_menu_at(&target, &menu, x, y);
    });
    widget.add_controller(gesture);
}
