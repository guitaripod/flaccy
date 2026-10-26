use crate::config::{REMOTE_CACHE_CAP_MAX_GB, REMOTE_CACHE_CAP_MIN_GB};
use crate::events::AppEvent;
use crate::ui::Ui;
use adw::prelude::*;
use flaccy_library::remote::servers::Server;
use flaccy_library::remote::service::Remote;
use gtk::glib;
use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

/// The Preferences page for OpenSubsonic servers: the saved servers with Test,
/// Refresh, Rename and Remove, an Add Server dialog, and the cache cap.
pub fn page(ui: &Rc<Ui>) -> adw::PreferencesPage {
    let page = adw::PreferencesPage::builder()
        .title("Servers")
        .icon_name("network-server-symbolic")
        .build();
    page.add(&crate::ui::flaccy_server::group(ui));
    page.add(&servers_group(ui));
    page.add(&cache_group(ui));
    page.add(&crate::ui::flaccy_server::nudge_group(ui));
    page
}

fn servers_group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder()
        .title("Servers")
        .description("Play a library from an OpenSubsonic server such as Navidrome. Its songs join your library next to the ones on this computer.")
        .build();
    let refresh_all = gtk::Button::builder()
        .child(
            &adw::ButtonContent::builder()
                .icon_name("view-refresh-symbolic")
                .label("Refresh")
                .build(),
        )
        .valign(gtk::Align::Center)
        .tooltip_text("Pull every server's songs again")
        .build();
    refresh_all.add_css_class("flat");
    {
        let ui = Rc::clone(ui);
        refresh_all.connect_clicked(move |_| ui.core.sync_remote_servers(true));
    }
    let add = gtk::Button::builder()
        .child(
            &adw::ButtonContent::builder()
                .icon_name("list-add-symbolic")
                .label("Add Server…")
                .build(),
        )
        .valign(gtk::Align::Center)
        .build();
    add.add_css_class("suggested-action");
    {
        let ui = Rc::clone(ui);
        add.connect_clicked(move |_| present_add(&ui, &Prefill::default()));
    }
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    header.append(&refresh_all);
    header.append(&add);
    group.set_header_suffix(Some(&header));

    let listed: Rc<RefCell<Vec<adw::ActionRow>>> = Rc::new(RefCell::new(Vec::new()));
    fill(ui, &group, &listed);
    {
        let ui = Rc::clone(ui);
        let listed = Rc::clone(&listed);
        let target = group.clone();
        ui.core.hub.clone().subscribe_widget(&header, move |_, event| {
            if matches!(event, AppEvent::RemoteChanged | AppEvent::LibraryReloaded) {
                fill(&ui, &target, &listed);
            }
        });
    }
    group
}

/// Rebuilds the server rows from the saved list, with the song counts and
/// whether each server answered last.
fn fill(ui: &Rc<Ui>, group: &adw::PreferencesGroup, listed: &RefCell<Vec<adw::ActionRow>>) {
    for old in listed.borrow_mut().drain(..) {
        group.remove(&old);
    }
    let Some(remote) = crate::remote::handle().cloned() else {
        return;
    };
    let counts = ui.core.db.remote_song_counts();
    let servers: Vec<Server> = remote
        .servers()
        .into_iter()
        .filter(|server| !server.flaccy_server)
        .collect();
    if servers.is_empty() {
        let row = adw::ActionRow::builder()
            .title("No servers yet")
            .subtitle("Add one to stream its library. Your own music keeps working either way.")
            .build();
        group.add(&row);
        listed.borrow_mut().push(row);
        return;
    }
    for server in servers {
        let row = server_row(ui, &remote, &server, counts.get(&server.id).copied().unwrap_or(0));
        group.add(&row);
        listed.borrow_mut().push(row);
    }
}

fn server_row(ui: &Rc<Ui>, remote: &Arc<Remote>, server: &Server, songs: usize) -> adw::ActionRow {
    let reachable = remote.manager().is_reachable(&server.id);
    let status = if reachable { "" } else { " · can't be reached right now" };
    let noun = if songs == 1 { "song" } else { "songs" };
    let row = adw::ActionRow::builder()
        .title(glib::markup_escape_text(&server.name))
        .subtitle(glib::markup_escape_text(&format!(
            "{} · {songs} {noun}{status}",
            server.address
        )))
        .build();
    row.add_prefix(&gtk::Image::from_icon_name("network-server-symbolic"));

    let test = gtk::Button::builder()
        .label("Test")
        .tooltip_text("Test the connection")
        .valign(gtk::Align::Center)
        .build();
    test.add_css_class("flat");
    let refresh = icon_button("view-refresh-symbolic", "Pull this server's songs again");
    let rename = icon_button("document-edit-symbolic", "Rename");
    let delete = icon_button("user-trash-symbolic", "Remove");
    delete.add_css_class("destructive-action");
    for button in [&test, &refresh, &rename, &delete] {
        row.add_suffix(button);
    }

    {
        let ui = Rc::clone(ui);
        let server = server.clone();
        let row = row.clone();
        test.connect_clicked(move |button| run_test(&ui, &row, button, &server));
    }
    {
        let ui = Rc::clone(ui);
        refresh.connect_clicked(move |_| ui.core.sync_remote_servers(true));
    }
    {
        let ui = Rc::clone(ui);
        let server = server.clone();
        rename.connect_clicked(move |_| present_rename(&ui, &server));
    }
    {
        let ui = Rc::clone(ui);
        let server = server.clone();
        delete.connect_clicked(move |_| present_remove(&ui, &server, songs));
    }
    row
}

fn icon_button(icon: &str, tooltip: &str) -> gtk::Button {
    let button = gtk::Button::builder()
        .icon_name(icon)
        .tooltip_text(tooltip)
        .valign(gtk::Align::Center)
        .build();
    button.add_css_class("flat");
    button
}

/// Tests a saved server on a worker thread and writes the answer into the
/// row: the server type and version, or the exact failure.
fn run_test(ui: &Rc<Ui>, row: &adw::ActionRow, button: &gtk::Button, server: &Server) {
    button.set_sensitive(false);
    row.set_subtitle("Testing the connection…");
    let (tx, rx) = async_channel::bounded(1);
    let tested = server.clone();
    std::thread::Builder::new()
        .name("flaccy-remote-test".into())
        .spawn(move || {
            let _ = tx.send_blocking(Remote::test(&tested));
        })
        .ok();
    let ui = Rc::clone(ui);
    let row = row.clone();
    let button = button.clone();
    glib::spawn_future_local(async move {
        let Ok(result) = rx.recv().await else { return };
        button.set_sensitive(true);
        match result {
            Ok(info) => {
                crate::logger::info("remote", &format!("test passed: {}", info.summary()));
                row.set_subtitle(&glib::markup_escape_text(&format!(
                    "Connected to {}. {} extensions.",
                    info.summary(),
                    info.extensions.len()
                )));
            }
            Err(error) => {
                crate::logger::warn("remote", &format!("test failed: {error}"));
                row.set_subtitle(&glib::markup_escape_text(&error.message()));
                ui.core.toast(&error.message());
            }
        }
    });
}

/// What the Add Server dialog opens with when a link or another dialog already
/// knows the address.
#[derive(Default)]
pub struct Prefill {
    pub address: String,
    pub name: String,
    pub api_key: String,
}

pub fn present_add(ui: &Rc<Ui>, prefill: &Prefill) {
    let dialog = adw::Dialog::builder()
        .title("Add Server")
        .content_width(460)
        .build();
    let group = adw::PreferencesGroup::new();
    let address = adw::EntryRow::builder().title("Address").build();
    address.set_input_purpose(gtk::InputPurpose::Url);
    let name = adw::EntryRow::builder().title("Name (optional)").build();
    let username = adw::EntryRow::builder().title("Username").build();
    let password = adw::PasswordEntryRow::builder().title("Password").build();
    let api_key = adw::PasswordEntryRow::builder()
        .title("API key (instead of a password)")
        .build();
    address.set_text(&prefill.address);
    name.set_text(&prefill.name);
    api_key.set_text(&prefill.api_key);
    for row in [&address, &name, &username] {
        group.add(row);
    }
    group.add(&password);
    group.add(&api_key);

    let status = gtk::Label::builder()
        .wrap(true)
        .xalign(0.0)
        .visible(false)
        .selectable(true)
        .build();
    let test = gtk::Button::with_label("Test");
    let add = gtk::Button::with_label("Add Server");
    add.add_css_class("suggested-action");
    let buttons = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .halign(gtk::Align::End)
        .build();
    buttons.append(&test);
    buttons.append(&add);

    let body = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(14)
        .margin_top(12)
        .margin_bottom(18)
        .margin_start(18)
        .margin_end(18)
        .build();
    body.append(&group);
    body.append(&status);
    body.append(&buttons);
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());
    toolbar.set_content(Some(&body));
    dialog.set_child(Some(&toolbar));

    let read_server = {
        let (address, name, username, password, api_key) = (
            address.clone(),
            name.clone(),
            username.clone(),
            password.clone(),
            api_key.clone(),
        );
        Rc::new(move || -> Result<Server, String> {
            let typed = address.text().to_string();
            let Some(normal) = flaccy_shared::remote::server_address::normalize(&typed) else {
                return Err("The server address can't be used. Type it like https://music.example.com or http://192.168.1.5:4533 and try again.".to_string());
            };
            let key = api_key.text().to_string();
            let secret = if key.trim().is_empty() { password.text().to_string() } else { key.clone() };
            let label = name.text().trim().to_string();
            let label = if label.is_empty() {
                normal.split_once("://").map(|(_, host)| host.to_string()).unwrap_or(normal.clone())
            } else {
                label
            };
            Ok(Server::new(&label, &normal, &username.text(), &secret, !key.trim().is_empty()))
        })
    };

    {
        let read_server = Rc::clone(&read_server);
        let status = status.clone();
        let test_button = test.clone();
        test.connect_clicked(move |_| {
            let server = match read_server() {
                Ok(server) => server,
                Err(message) => {
                    show_status(&status, &message, false);
                    return;
                }
            };
            show_status(&status, "Testing the connection…", true);
            test_button.set_sensitive(false);
            let (tx, rx) = async_channel::bounded(1);
            std::thread::Builder::new()
                .name("flaccy-remote-test".into())
                .spawn(move || {
                    let _ = tx.send_blocking(Remote::test(&server));
                })
                .ok();
            let status = status.clone();
            let test_button = test_button.clone();
            glib::spawn_future_local(async move {
                let Ok(result) = rx.recv().await else { return };
                test_button.set_sensitive(true);
                match result {
                    Ok(info) => show_status(&status, &format!("Connected to {}.", info.summary()), true),
                    Err(error) => show_status(&status, &error.message(), false),
                }
            });
        });
    }
    {
        let ui = Rc::clone(ui);
        let dialog = dialog.clone();
        let status = status.clone();
        add.connect_clicked(move |_| {
            let server = match read_server() {
                Ok(server) => server,
                Err(message) => {
                    show_status(&status, &message, false);
                    return;
                }
            };
            let Some(remote) = crate::remote::handle() else {
                show_status(&status, "Servers are unavailable because Flaccy's local playback proxy didn't start. Restart Flaccy and try again.", false);
                return;
            };
            if let Err(message) = remote.add_server(server.clone()) {
                show_status(&status, &message, false);
                return;
            }
            crate::logger::info("remote", &format!("server {} added", server.name));
            dialog.close();
            ui.core.toast(&format!("Added {}. Pulling its songs…", server.name));
            ui.core.sync_remote_servers(true);
        });
    }
    dialog.present(Some(&ui.window));
}

fn show_status(label: &gtk::Label, message: &str, neutral: bool) {
    label.set_label(message);
    label.set_visible(true);
    label.remove_css_class("error");
    label.remove_css_class("success");
    label.add_css_class(if neutral { "success" } else { "error" });
}

fn present_rename(ui: &Rc<Ui>, server: &Server) {
    let entry = gtk::Entry::builder().text(&server.name).activates_default(true).build();
    let dialog = adw::AlertDialog::builder()
        .heading("Rename Server")
        .body("The name shows in the Songs filter and in messages. Its songs stay where they are.")
        .close_response("cancel")
        .default_response("rename")
        .extra_child(&entry)
        .build();
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("rename", "Rename");
    dialog.set_response_appearance("rename", adw::ResponseAppearance::Suggested);
    let ui_for_response = Rc::clone(ui);
    let id = server.id.clone();
    dialog.connect_response(None, move |_, response| {
        if response != "rename" {
            return;
        }
        let name = entry.text().trim().to_string();
        if name.is_empty() {
            ui_for_response.core.toast("A server needs a name. Type one and try again.");
            return;
        }
        if let Some(remote) = crate::remote::handle() {
            match remote.rename_server(&id, &name) {
                Ok(()) => ui_for_response.core.reload_library(),
                Err(message) => ui_for_response.core.toast(&message),
            }
        }
    });
    dialog.present(Some(&ui.window));
}

fn present_remove(ui: &Rc<Ui>, server: &Server, songs: usize) {
    let dialog = adw::AlertDialog::builder()
        .heading(format!("Remove {}?", server.name))
        .body(format!(
            "Its {songs} songs leave your library and any playlists, and the songs cached or downloaded from it are deleted from this computer. The server itself is not changed."
        ))
        .close_response("cancel")
        .default_response("cancel")
        .build();
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("remove", "Remove Server");
    dialog.set_response_appearance("remove", adw::ResponseAppearance::Destructive);
    let ui_for_response = Rc::clone(ui);
    let id = server.id.clone();
    let name = server.name.clone();
    dialog.connect_response(None, move |_, response| {
        if response != "remove" {
            return;
        }
        let Some(remote) = crate::remote::handle().cloned() else { return };
        let ui = Rc::clone(&ui_for_response);
        let id = id.clone();
        let name = name.clone();
        let (tx, rx) = async_channel::bounded(1);
        std::thread::Builder::new()
            .name("flaccy-remote-remove".into())
            .spawn(move || {
                let _ = tx.send_blocking(remote.remove_server(&id));
            })
            .ok();
        glib::spawn_future_local(async move {
            let Ok(result) = rx.recv().await else { return };
            match result {
                Ok(removed) => {
                    ui.core.player.handle_deleted(&gone_paths(&ui));
                    ui.core.reload_library();
                    ui.core.toast(&format!("Removed {name} and its {removed} songs from the library."));
                }
                Err(message) => ui.core.toast(&message),
            }
        });
    });
    dialog.present(Some(&ui.window));
}

/// The queue's remote songs whose server no longer exists, once the server list
/// has changed: these leave the queue the way a deleted file does.
fn gone_paths(ui: &Rc<Ui>) -> std::collections::HashSet<String> {
    let known: std::collections::HashSet<String> = crate::remote::handle()
        .map(|remote| remote.servers().into_iter().map(|server| server.id).collect())
        .unwrap_or_default();
    ui.core
        .player
        .queue_snapshot()
        .queue
        .into_iter()
        .filter(|track| {
            crate::remote::server_of(&track.rel_path).is_some_and(|server| !known.contains(&server))
        })
        .map(|track| track.rel_path)
        .collect()
}

fn cache_group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder()
        .title("Cache")
        .description("Songs you stream are kept here so they replay without the server. The least recently played go first once the limit is reached. Songs you download stay outside the limit.")
        .build();
    let limit = adw::SpinRow::with_range(
        f64::from(REMOTE_CACHE_CAP_MIN_GB),
        f64::from(REMOTE_CACHE_CAP_MAX_GB),
        1.0,
    );
    limit.set_title("Cache Limit (GB)");
    limit.set_value(f64::from(ui.core.config.borrow().remote_cache_cap_gb));
    let usage = adw::ActionRow::builder().title("In Use").build();
    render_usage(&usage);
    {
        let ui = Rc::clone(ui);
        let usage = usage.clone();
        limit.connect_value_notify(move |row| {
            ui.core.config.borrow_mut().remote_cache_cap_gb = row.value().round() as u32;
            ui.core.save_config();
            let cap = ui.core.config.borrow().remote_cache_cap_bytes();
            if let Some(remote) = crate::remote::handle() {
                remote.set_cap_bytes(cap);
            }
            render_usage(&usage);
        });
    }
    group.add(&limit);
    group.add(&usage);
    group
}

fn render_usage(row: &adw::ActionRow) {
    let (cached, kept) = crate::remote::handle().map(|remote| remote.usage()).unwrap_or((0, 0));
    row.set_subtitle(&format!(
        "{} cached, {} downloaded",
        format_bytes(cached),
        format_bytes(kept)
    ));
}

fn format_bytes(bytes: u64) -> String {
    const MB: f64 = 1024.0 * 1024.0;
    let megabytes = bytes as f64 / MB;
    if megabytes >= 1024.0 {
        format!("{:.1} GB", megabytes / 1024.0)
    } else {
        format!("{megabytes:.0} MB")
    }
}

#[cfg(test)]
mod tests {
    use super::format_bytes;

    #[test]
    fn sizes_read_in_megabytes_until_a_gigabyte() {
        assert_eq!(format_bytes(0), "0 MB");
        assert_eq!(format_bytes(5 * 1024 * 1024), "5 MB");
        assert_eq!(format_bytes(3 * 1024 * 1024 * 1024), "3.0 GB");
    }
}
