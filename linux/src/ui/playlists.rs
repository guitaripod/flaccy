use crate::events::AppEvent;
use crate::library::{format_time, Track};
use crate::ui::{context, Ui};
use adw::prelude::*;
use gtk::gdk;
use gtk::pango;
use std::cell::RefCell;
use std::rc::Rc;

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .valign(gtk::Align::Start)
        .build();
    list.add_css_class("boxed-list");

    let ids: Rc<RefCell<Vec<i64>>> = Rc::new(RefCell::new(Vec::new()));

    {
        let ui = Rc::clone(ui);
        let ids = Rc::clone(&ids);
        list.connect_row_activated(move |_, row| {
            let id = ids.borrow().get(row.index().max(0) as usize).copied();
            if let Some(id) = id {
                push_playlist_detail(&ui, id);
            }
        });
    }

    let new_button = gtk::Button::builder().label("New Playlist").build();
    new_button.add_css_class("pill");
    new_button.set_halign(gtk::Align::Start);
    {
        let ui = Rc::clone(ui);
        new_button.connect_clicked(move |_| prompt_new_playlist(&ui, None));
    }

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .margin_top(18)
        .margin_bottom(18)
        .margin_start(18)
        .margin_end(18)
        .build();
    content.append(&new_button);
    content.append(&list);

    let empty = adw::StatusPage::builder()
        .icon_name("view-list-symbolic")
        .title("No Playlists")
        .description("Create a playlist, then add songs from any track's context menu.")
        .build();
    let empty_button = gtk::Button::with_label("New Playlist");
    empty_button.add_css_class("pill");
    empty_button.add_css_class("suggested-action");
    empty_button.set_halign(gtk::Align::Center);
    {
        let ui = Rc::clone(ui);
        empty_button.connect_clicked(move |_| prompt_new_playlist(&ui, None));
    }
    empty.set_child(Some(&empty_button));

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&adw::Clamp::builder().maximum_size(760).child(&content).build())
        .build();
    ui.register_scroller(&scroll);

    let stack = gtk::Stack::new();
    stack.set_hhomogeneous(false);
    stack.set_vhomogeneous(false);
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&scroll, Some("list"));

    let rebuild = {
        let list = list.clone();
        let stack = stack.clone();
        let ids = Rc::clone(&ids);
        let ui = Rc::clone(ui);
        move || {
            while let Some(child) = list.first_child() {
                list.remove(&child);
            }
            let playlists = ui.core.db.fetch_playlists();
            let mut collected = Vec::new();
            for playlist in &playlists {
                collected.push(playlist.id);
                let row_box = gtk::Box::builder()
                    .orientation(gtk::Orientation::Horizontal)
                    .spacing(14)
                    .margin_top(10)
                    .margin_bottom(10)
                    .margin_start(10)
                    .margin_end(10)
                    .build();
                row_box.append(&gtk::Image::from_icon_name("view-list-symbolic"));
                let name = gtk::Label::builder()
                    .label(&playlist.name)
                    .xalign(0.0)
                    .hexpand(true)
                    .ellipsize(pango::EllipsizeMode::End)
                    .build();
                name.add_css_class("album-title");
                row_box.append(&name);
                let count = gtk::Label::new(Some(&format!(
                    "{} track{}",
                    playlist.track_count,
                    if playlist.track_count == 1 { "" } else { "s" }
                )));
                count.add_css_class("dim");
                count.add_css_class("caption");
                row_box.append(&count);
                let list_row = gtk::ListBoxRow::builder().child(&row_box).build();
                attach_playlist_list_menu(&list_row, playlist.id);
                list.append(&list_row);
            }
            *ids.borrow_mut() = collected;
            stack.set_visible_child_name(if playlists.is_empty() { "empty" } else { "list" });
        }
    };
    rebuild();

    {
        let rebuild = rebuild.clone();
        ui.core.hub.subscribe_widget(&stack, move |_, event| {
            if let AppEvent::LibraryReloaded = event {
                rebuild();
            }
        });
    }

    stack.upcast()
}

/// Playlist picker backing the context menus' "Add to Playlist…" item; a flat
/// dialog instead of a nested submenu because GtkPopoverMenu (4.22) truncates
/// menus that embed submenu sections.
pub fn present_add_to_playlist(ui: &Rc<Ui>, rel_path: &str) {
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .build();
    list.add_css_class("boxed-list");

    let dialog = adw::Dialog::builder().content_width(360).build();

    for playlist in ui.core.db.fetch_playlists() {
        let row = adw::ActionRow::builder()
            .title(&playlist.name)
            .subtitle(format!(
                "{} song{}",
                playlist.track_count,
                if playlist.track_count == 1 { "" } else { "s" }
            ))
            .activatable(true)
            .build();
        let ui = Rc::clone(ui);
        let rel = rel_path.to_string();
        let name = playlist.name.clone();
        let dialog = dialog.clone();
        row.connect_activated(move |_| {
            match ui.core.db.add_track_to_playlist(playlist.id, &rel) {
                Ok(()) => {
                    ui.core.hub.emit(&AppEvent::LibraryReloaded);
                    ui.core.toast(&format!("Added to {name}"));
                }
                Err(err) => {
                    crate::logger::error("database", &format!("playlist add failed: {err}"));
                }
            }
            dialog.close();
        });
        list.append(&row);
    }

    let new_row = adw::ActionRow::builder()
        .title("New Playlist…")
        .activatable(true)
        .build();
    new_row.add_prefix(&gtk::Image::from_icon_name("list-add-symbolic"));
    {
        let ui = Rc::clone(ui);
        let rel = rel_path.to_string();
        let dialog = dialog.clone();
        new_row.connect_activated(move |_| {
            dialog.close();
            prompt_new_playlist(&ui, Some(rel.clone()));
        });
    }
    list.append(&new_row);

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .margin_top(8)
        .margin_bottom(18)
        .margin_start(18)
        .margin_end(18)
        .build();
    content.append(&list);
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .propagate_natural_height(true)
        .max_content_height(480)
        .child(&content)
        .build();

    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(
        &adw::HeaderBar::builder()
            .title_widget(&adw::WindowTitle::new("Add to Playlist", ""))
            .build(),
    );
    toolbar.set_content(Some(&scroll));
    dialog.set_child(Some(&toolbar));
    dialog.present(Some(&ui.window));
}

pub fn prompt_new_playlist(ui: &Rc<Ui>, add_rel_path: Option<String>) {
    let dialog = adw::AlertDialog::builder()
        .heading("New Playlist")
        .body("Name your new playlist.")
        .close_response("cancel")
        .default_response("create")
        .build();
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("create", "Create");
    dialog.set_response_appearance("create", adw::ResponseAppearance::Suggested);

    let entry = gtk::Entry::builder()
        .placeholder_text("Playlist name")
        .activates_default(true)
        .build();
    dialog.set_extra_child(Some(&entry));

    let window = ui.window.clone();
    let ui = Rc::clone(ui);
    dialog.connect_response(None, move |_, response| {
        if response != "create" {
            return;
        }
        let name = entry.text().trim().to_string();
        if name.is_empty() {
            return;
        }
        match ui.core.db.create_playlist(&name) {
            Ok(id) => {
                if let Some(rel) = &add_rel_path {
                    let _ = ui.core.db.add_track_to_playlist(id, rel);
                }
                crate::logger::info("database", &format!("created playlist '{name}'"));
                ui.core.hub.emit(&AppEvent::LibraryReloaded);
            }
            Err(err) => {
                crate::logger::error("database", &format!("create playlist failed: {err}"));
            }
        }
    });
    dialog.present(Some(&window));
}

fn push_playlist_detail(ui: &Rc<Ui>, playlist_id: i64) {
    let name = ui
        .core
        .db
        .playlist_name(playlist_id)
        .unwrap_or_else(|| "Playlist".to_string());

    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .valign(gtk::Align::Start)
        .build();
    list.add_css_class("boxed-list");

    let entries: Rc<RefCell<Vec<(i64, Track)>>> = Rc::new(RefCell::new(Vec::new()));

    let rebuild = {
        let list = list.clone();
        let entries = Rc::clone(&entries);
        let ui = Rc::clone(ui);
        Rc::new(move || {
            while let Some(child) = list.first_child() {
                list.remove(&child);
            }
            let library = ui.core.library.borrow().clone();
            let by_rel_path: std::collections::HashMap<&str, &Track> = library
                .tracks
                .iter()
                .map(|track| (track.rel_path.as_str(), track))
                .collect();
            let rows = ui.core.db.playlist_tracks(playlist_id);
            let mut collected = Vec::new();
            for row in rows {
                let Some(track) = by_rel_path.get(row.rel_path.as_str()).map(|t| (*t).clone()) else {
                    continue;
                };
                collected.push((row.row_id, track.clone()));
                let index = collected.len();
                let row_box = gtk::Box::builder()
                    .orientation(gtk::Orientation::Horizontal)
                    .spacing(12)
                    .margin_top(10)
                    .margin_bottom(10)
                    .margin_start(12)
                    .margin_end(12)
                    .build();
                let number = gtk::Label::builder()
                    .label(index.to_string())
                    .width_chars(3)
                    .xalign(1.0)
                    .build();
                number.add_css_class("track-number");
                row_box.append(&number);
                let text_box = gtk::Box::new(gtk::Orientation::Vertical, 2);
                let title = gtk::Label::builder()
                    .label(&track.title)
                    .xalign(0.0)
                    .ellipsize(pango::EllipsizeMode::End)
                    .build();
                text_box.append(&title);
                let artist = gtk::Label::builder()
                    .label(&track.artist)
                    .xalign(0.0)
                    .ellipsize(pango::EllipsizeMode::End)
                    .build();
                artist.add_css_class("dim");
                artist.add_css_class("caption");
                text_box.append(&artist);
                text_box.set_hexpand(true);
                row_box.append(&text_box);
                let duration = gtk::Label::new(Some(&format_time(track.duration)));
                duration.add_css_class("duration-label");
                row_box.append(&duration);

                let list_row = gtk::ListBoxRow::builder().child(&row_box).build();
                attach_playlist_row_menu(&ui, &list_row, playlist_id, row.row_id, &track);
                attach_reorder_dnd(&ui, &list_row, &list, playlist_id, &entries);
                list.append(&list_row);
            }
            *entries.borrow_mut() = collected;
        })
    };
    rebuild();

    {
        let ui = Rc::clone(ui);
        let entries = Rc::clone(&entries);
        list.connect_row_activated(move |_, row| {
            let tracks: Vec<Track> = entries.borrow().iter().map(|(_, t)| t.clone()).collect();
            let index = row.index().max(0) as usize;
            if index < tracks.len() {
                ui.core.play_tracks(tracks, index);
            }
        });
    }

    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .build();
    let title = gtk::Label::builder().label(&name).xalign(0.0).hexpand(true).build();
    title.add_css_class("title-1");
    header.append(&title);

    let play = gtk::Button::builder().label("Play").build();
    play.add_css_class("pill");
    play.add_css_class("suggested-action");
    {
        let ui = Rc::clone(ui);
        let entries = Rc::clone(&entries);
        play.connect_clicked(move |_| {
            let tracks: Vec<Track> = entries.borrow().iter().map(|(_, t)| t.clone()).collect();
            if !tracks.is_empty() {
                ui.core.play_tracks(tracks, 0);
            }
        });
    }
    header.append(&play);

    let delete = gtk::Button::builder().label("Delete").build();
    delete.add_css_class("pill");
    delete.add_css_class("destructive-action");
    {
        let ui = Rc::clone(ui);
        delete.connect_clicked(move |_| {
            let dialog = adw::AlertDialog::builder()
                .heading("Delete Playlist?")
                .body("This removes the playlist. Your music files stay untouched.")
                .close_response("cancel")
                .build();
            dialog.add_response("cancel", "Cancel");
            dialog.add_response("delete", "Delete");
            dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
            let window = ui.window.clone();
            let ui = Rc::clone(&ui);
            dialog.connect_response(None, move |_, response| {
                if response == "delete" {
                    let _ = ui.core.db.delete_playlist(playlist_id);
                    ui.core.hub.emit(&AppEvent::LibraryReloaded);
                    ui.nav.pop();
                }
            });
            dialog.present(Some(&window));
        });
    }
    header.append(&delete);

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .margin_top(24)
        .margin_bottom(24)
        .margin_start(24)
        .margin_end(24)
        .build();
    content.append(&header);
    content.append(&list);

    let hint = gtk::Label::new(Some("Drag rows to reorder · right-click to remove"));
    hint.add_css_class("dim-more");
    hint.add_css_class("caption");
    hint.set_xalign(0.0);
    content.append(&hint);

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&adw::Clamp::builder().maximum_size(760).child(&content).build())
        .build();
    ui.register_scroller(&scroll);

    {
        let rebuild = Rc::clone(&rebuild);
        ui.core.hub.subscribe_widget(&scroll, move |_, event| {
            if let AppEvent::LibraryReloaded = event {
                rebuild();
            }
        });
    }

    let page = adw::NavigationPage::builder().title(&name).child(&scroll).build();
    ui.nav.push(&page);
}

fn attach_playlist_list_menu(row: &gtk::ListBoxRow, playlist_id: i64) {
    let gesture = gtk::GestureClick::builder()
        .button(gdk::BUTTON_SECONDARY)
        .build();
    let target = row.clone();
    gesture.connect_pressed(move |_, _, x, y| {
        context::popup_menu_at(&target, &playlist_list_menu(playlist_id), x, y);
    });
    row.add_controller(gesture);
}

fn playlist_list_menu(playlist_id: i64) -> gtk::gio::Menu {
    let menu = gtk::gio::Menu::new();
    let play_section = gtk::gio::Menu::new();
    play_section.append_item(&playlist_item("Play", "win.playlist-play", playlist_id));
    play_section.append_item(&playlist_item("Shuffle", "win.playlist-shuffle", playlist_id));
    menu.append_section(None, &play_section);
    let manage_section = gtk::gio::Menu::new();
    manage_section.append_item(&playlist_item("Rename…", "win.playlist-rename", playlist_id));
    manage_section.append_item(&playlist_item("Delete", "win.playlist-delete", playlist_id));
    menu.append_section(None, &manage_section);
    menu
}

fn playlist_item(label: &str, action: &str, playlist_id: i64) -> gtk::gio::MenuItem {
    let entry = gtk::gio::MenuItem::new(Some(label), None);
    entry.set_action_and_target_value(Some(action), Some(&playlist_id.to_variant()));
    entry
}

/// Resolves a playlist's stored track order against the live library, dropping
/// rows whose file has since left the library.
fn resolve_playlist_tracks(ui: &Rc<Ui>, playlist_id: i64) -> Vec<Track> {
    let library = ui.core.library.borrow().clone();
    let by_rel_path: std::collections::HashMap<&str, &Track> = library
        .tracks
        .iter()
        .map(|track| (track.rel_path.as_str(), track))
        .collect();
    ui.core
        .db
        .playlist_tracks(playlist_id)
        .into_iter()
        .filter_map(|row| by_rel_path.get(row.rel_path.as_str()).map(|track| (*track).clone()))
        .collect()
}

pub fn play_playlist(ui: &Rc<Ui>, playlist_id: i64, shuffle: bool) {
    let tracks = resolve_playlist_tracks(ui, playlist_id);
    if tracks.is_empty() {
        ui.core.toast("Playlist has no playable tracks");
        return;
    }
    if shuffle != ui.core.player.shuffle_enabled() {
        ui.core.player.toggle_shuffle();
    }
    ui.core.play_tracks(tracks, 0);
}

pub fn prompt_rename_playlist(ui: &Rc<Ui>, playlist_id: i64) {
    let current = ui.core.db.playlist_name(playlist_id).unwrap_or_default();
    let dialog = adw::AlertDialog::builder()
        .heading("Rename Playlist")
        .body("Choose a new name.")
        .close_response("cancel")
        .default_response("rename")
        .build();
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("rename", "Rename");
    dialog.set_response_appearance("rename", adw::ResponseAppearance::Suggested);

    let entry = gtk::Entry::builder()
        .text(&current)
        .activates_default(true)
        .build();
    dialog.set_extra_child(Some(&entry));

    let window = ui.window.clone();
    let ui = Rc::clone(ui);
    dialog.connect_response(None, move |_, response| {
        if response != "rename" {
            return;
        }
        let name = entry.text().trim().to_string();
        if name.is_empty() {
            return;
        }
        match ui.core.db.rename_playlist(playlist_id, &name) {
            Ok(()) => {
                crate::logger::info("database", &format!("renamed playlist {playlist_id} to '{name}'"));
                ui.core.hub.emit(&AppEvent::LibraryReloaded);
            }
            Err(err) => {
                crate::logger::error("database", &format!("rename playlist failed: {err}"));
            }
        }
    });
    dialog.present(Some(&window));
}

pub fn confirm_delete_playlist(ui: &Rc<Ui>, playlist_id: i64) {
    let dialog = adw::AlertDialog::builder()
        .heading("Delete Playlist?")
        .body("This removes the playlist. Your music files stay untouched.")
        .close_response("cancel")
        .build();
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("delete", "Delete");
    dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
    let window = ui.window.clone();
    let ui = Rc::clone(ui);
    dialog.connect_response(None, move |_, response| {
        if response == "delete" {
            let _ = ui.core.db.delete_playlist(playlist_id);
            ui.core.hub.emit(&AppEvent::LibraryReloaded);
        }
    });
    dialog.present(Some(&window));
}

fn attach_playlist_row_menu(
    ui: &Rc<Ui>,
    row: &gtk::ListBoxRow,
    playlist_id: i64,
    row_id: i64,
    track: &Track,
) {
    let gesture = gtk::GestureClick::builder()
        .button(gdk::BUTTON_SECONDARY)
        .build();
    let ui = Rc::clone(ui);
    let target = row.clone();
    let rel_path = track.rel_path.clone();
    gesture.connect_pressed(move |_, _, x, y| {
        let loved = ui
            .core
            .library
            .borrow()
            .track_by_rel_path(&rel_path)
            .map(|t| t.loved)
            .unwrap_or(false);
        let menu = context::track_menu(&rel_path, loved);
        let remove_section = gtk::gio::Menu::new();
        let remove_item = gtk::gio::MenuItem::new(Some("Remove from Playlist"), None);
        remove_item.set_action_and_target_value(
            Some("win.playlist-remove-row"),
            Some(&(playlist_id, row_id).to_variant()),
        );
        remove_section.append_item(&remove_item);
        menu.append_section(None, &remove_section);
        context::popup_menu_at(&target, &menu, x, y);
    });
    row.add_controller(gesture);
}

fn attach_reorder_dnd(
    ui: &Rc<Ui>,
    row: &gtk::ListBoxRow,
    list: &gtk::ListBox,
    playlist_id: i64,
    entries: &Rc<RefCell<Vec<(i64, Track)>>>,
) {
    let drag = gtk::DragSource::builder().actions(gdk::DragAction::MOVE).build();
    {
        let row = row.clone();
        drag.connect_prepare(move |_, _, _| {
            Some(gdk::ContentProvider::for_value(&(row.index()).to_value()))
        });
    }
    row.add_controller(drag);

    let drop = gtk::DropTarget::new(i32::static_type(), gdk::DragAction::MOVE);
    {
        let ui = Rc::clone(ui);
        let list = list.clone();
        let entries = Rc::clone(entries);
        let row = row.clone();
        drop.connect_drop(move |_, value, _, _| {
            let Ok(source_index) = value.get::<i32>() else { return false };
            let target_index = row.index();
            if source_index == target_index || source_index < 0 || target_index < 0 {
                return false;
            }
            let mut order: Vec<i64> = entries.borrow().iter().map(|(id, _)| *id).collect();
            if source_index as usize >= order.len() {
                return false;
            }
            let moved = order.remove(source_index as usize);
            let insert_at = (target_index as usize).min(order.len());
            order.insert(insert_at, moved);
            if let Err(err) = ui.core.db.reorder_playlist(playlist_id, &order) {
                crate::logger::error("database", &format!("reorder failed: {err}"));
                return false;
            }
            let _ = &list;
            ui.core.hub.emit(&AppEvent::LibraryReloaded);
            true
        });
    }
    row.add_controller(drop);
}
