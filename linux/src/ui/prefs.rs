use crate::config::{self, Session};
use crate::events::AppEvent;
use crate::lastfm::{self, LastFmClient};
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use gtk::gio;
use std::cell::RefCell;
use std::rc::Rc;

pub fn present(ui: &Rc<Ui>) {
    let dialog = adw::PreferencesDialog::builder().title("Preferences").build();
    let page = adw::PreferencesPage::builder()
        .title("General")
        .icon_name("emblem-system-symbolic")
        .build();

    page.add(&appearance_group(ui));
    page.add(&library_group(ui));
    if lastfm::keys_available() {
        page.add(&lastfm_group(ui));
    }
    page.add(&about_group());

    dialog.add(&page);
    dialog.present(Some(&ui.window));
}

fn appearance_group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder().title("Appearance").build();
    let model = gtk::StringList::new(&["System", "Light", "Dark"]);
    let row = adw::ComboRow::builder()
        .title("Color Scheme")
        .subtitle("Follow the system or force a look")
        .model(&model)
        .build();
    let selected = match ui.core.config.borrow().appearance.as_str() {
        "light" => 1,
        "dark" => 2,
        _ => 0,
    };
    row.set_selected(selected);
    {
        let ui = Rc::clone(ui);
        row.connect_selected_notify(move |row| {
            let appearance = match row.selected() {
                1 => "light",
                2 => "dark",
                _ => "system",
            };
            ui.core.config.borrow_mut().appearance = appearance.to_string();
            ui.core.save_config();
            crate::ui::window::apply_color_scheme(appearance);
            crate::logger::info("ui", &format!("appearance set to {appearance}"));
        });
    }
    group.add(&row);
    group
}

fn library_group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder().title("Library").build();

    let folder_row = adw::ActionRow::builder()
        .title("Music Folder")
        .subtitle(ui.core.music_root().display().to_string())
        .build();
    let choose = gtk::Button::with_label("Choose…");
    choose.set_valign(gtk::Align::Center);
    {
        let ui = Rc::clone(ui);
        let folder_row = folder_row.clone();
        choose.connect_clicked(move |_| {
            let dialog = gtk::FileDialog::builder().title("Choose Music Folder").build();
            let ui = Rc::clone(&ui);
            let window = ui.window.clone();
            let folder_row = folder_row.clone();
            dialog.select_folder(
                Some(&window),
                None::<&gio::Cancellable>,
                move |result| {
                    let Ok(folder) = result else { return };
                    let Some(path) = folder.path() else { return };
                    crate::logger::info(
                        "library",
                        &format!("music folder changed to {}", path.display()),
                    );
                    ui.core.config.borrow_mut().music_dir =
                        Some(path.display().to_string());
                    ui.core.save_config();
                    ui.core.player.set_root(path.clone());
                    folder_row.set_subtitle(&path.display().to_string());
                    ui.core.rescan();
                },
            );
        });
    }
    folder_row.add_suffix(&choose);
    group.add(&folder_row);

    let autoplay_row = adw::SwitchRow::builder()
        .title("Autoplay Similar Music")
        .subtitle("Keep the music going when the queue ends")
        .active(ui.core.config.borrow().autoplay_continuation)
        .build();
    {
        let ui = Rc::clone(ui);
        autoplay_row.connect_active_notify(move |row| {
            ui.core.config.borrow_mut().autoplay_continuation = row.is_active();
            ui.core.save_config();
            crate::logger::info(
                "ui",
                &format!("autoplay continuation set to {}", row.is_active()),
            );
        });
    }
    group.add(&autoplay_row);

    let rescan_row = adw::ActionRow::builder()
        .title("Rescan Library")
        .subtitle("Diff the folder against the database")
        .build();
    let rescan = gtk::Button::with_label("Rescan");
    rescan.set_valign(gtk::Align::Center);
    {
        let ui = Rc::clone(ui);
        rescan.connect_clicked(move |_| ui.core.rescan());
    }
    rescan_row.add_suffix(&rescan);
    group.add(&rescan_row);

    group
}

fn lastfm_group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder()
        .title("Last.fm")
        .description("Scrobble what you play")
        .build();

    let row = adw::ActionRow::builder().build();
    let button = gtk::Button::new();
    button.set_valign(gtk::Align::Center);
    row.add_suffix(&button);
    group.add(&row);

    let pending_token: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));

    let refresh: Rc<dyn Fn()> = {
        let ui = Rc::clone(ui);
        let row = row.clone();
        let button = button.clone();
        let pending_token = Rc::clone(&pending_token);
        Rc::new(move || {
            let session = ui.core.session.borrow().clone();
            match session {
                Some(session) => {
                    row.set_title(&format!("Connected as {}", session.username));
                    row.set_subtitle("Scrobbling and loved tracks are live");
                    button.set_label("Disconnect");
                    button.remove_css_class("suggested-action");
                    button.add_css_class("destructive-action");
                }
                None => {
                    if pending_token.borrow().is_some() {
                        row.set_title("Waiting for authorization…");
                        row.set_subtitle("Approve flaccy in your browser, then confirm here");
                        button.set_label("I've Authorized");
                    } else {
                        row.set_title("Not Connected");
                        row.set_subtitle("Authorize flaccy with your Last.fm account");
                        button.set_label("Connect…");
                    }
                    button.remove_css_class("destructive-action");
                    button.add_css_class("suggested-action");
                }
            }
        })
    };
    refresh();

    {
        let ui = Rc::clone(ui);
        let pending_token = Rc::clone(&pending_token);
        let refresh = Rc::clone(&refresh);
        button.connect_clicked(move |_| {
            let connected = ui.core.session.borrow().is_some();
            if connected {
                *ui.core.session.borrow_mut() = None;
                config::delete_session();
                crate::scrobbler::disconnect_cleanup(&ui.core);
                *pending_token.borrow_mut() = None;
                refresh();
                return;
            }
            let token = pending_token.borrow().clone();
            match token {
                None => begin_auth(&ui, &pending_token, &refresh),
                Some(token) => finish_auth(&ui, token, &pending_token, &refresh),
            }
        });
    }

    group
}

fn begin_auth(
    ui: &Rc<Ui>,
    pending_token: &Rc<RefCell<Option<String>>>,
    refresh: &Rc<dyn Fn()>,
) {
    let Some(client) = LastFmClient::new(None) else { return };
    let (tx, rx) = async_channel::bounded::<Result<String, String>>(1);
    std::thread::spawn(move || {
        let _ = tx.send_blocking(client.get_token());
    });
    let ui = Rc::clone(ui);
    let pending_token = Rc::clone(pending_token);
    let refresh = Rc::clone(refresh);
    glib::spawn_future_local(async move {
        match rx.recv().await {
            Ok(Ok(token)) => {
                let url = lastfm::auth_url(lastfm::API_KEY.unwrap_or(""), &token);
                *pending_token.borrow_mut() = Some(token);
                refresh();
                gtk::UriLauncher::new(&url).launch(
                    Some(&ui.window),
                    None::<&gio::Cancellable>,
                    |result| {
                        if let Err(err) = result {
                            crate::logger::warn("auth", &format!("browser launch failed: {err}"));
                        }
                    },
                );
                crate::logger::info("auth", "last.fm auth token requested, browser opened");
            }
            Ok(Err(err)) => {
                crate::logger::error("auth", &format!("auth.getToken failed: {err}"));
            }
            Err(_) => {}
        }
    });
}

fn finish_auth(
    ui: &Rc<Ui>,
    token: String,
    pending_token: &Rc<RefCell<Option<String>>>,
    refresh: &Rc<dyn Fn()>,
) {
    let Some(client) = LastFmClient::new(None) else { return };
    let (tx, rx) = async_channel::bounded::<Result<(String, String), String>>(1);
    std::thread::spawn(move || {
        let _ = tx.send_blocking(client.get_session(&token));
    });
    let ui = Rc::clone(ui);
    let pending_token = Rc::clone(pending_token);
    let refresh = Rc::clone(refresh);
    glib::spawn_future_local(async move {
        match rx.recv().await {
            Ok(Ok((key, username))) => {
                let session = Session {
                    key,
                    username: username.clone(),
                };
                config::save_session(&session);
                *ui.core.session.borrow_mut() = Some(session);
                *pending_token.borrow_mut() = None;
                crate::logger::info("auth", &format!("last.fm connected as {username}"));
                ui.core.hub.emit(&AppEvent::LastFmChanged);
                crate::scrobbler::startup_maintenance(&ui.core);
                refresh();
            }
            Ok(Err(err)) => {
                crate::logger::error("auth", &format!("auth.getSession failed: {err}"));
                *pending_token.borrow_mut() = None;
                refresh();
            }
            Err(_) => {}
        }
    });
}

fn about_group() -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder().title("About").build();
    let version_row = adw::ActionRow::builder()
        .title("Flaccy for Linux")
        .subtitle(format!(
            "Version {} · GTK4 + GStreamer · sibling of the iOS FLAC player",
            env!("CARGO_PKG_VERSION")
        ))
        .build();
    group.add(&version_row);
    let lyrics_row = adw::ActionRow::builder()
        .title("Lyrics")
        .subtitle("Provided by lrclib.net")
        .build();
    group.add(&lyrics_row);
    group
}
