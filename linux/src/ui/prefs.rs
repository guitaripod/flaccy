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

    page.add(&hero_group(ui));
    page.add(&appearance_group(ui));
    page.add(&library_group(ui));
    if lastfm::keys_available() {
        page.add(&lastfm_group(ui));
    }
    page.add(&about_group());

    dialog.add(&page);
    dialog.present(Some(&ui.window));
}

/// A branded banner atop Preferences: an app glyph, the wordmark, and a live
/// dashboard of the library — Albums, Tracks and all-time Plays. Its background
/// keys off the same accent tokens as the rest of the app, so it retints with
/// the active theme.
fn hero_group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::new();
    group.add(&build_hero(ui));
    group
}

fn build_hero(ui: &Rc<Ui>) -> gtk::Box {
    let hero = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(20)
        .build();
    hero.add_css_class("flaccy-hero");
    hero.append(&hero_identity());

    let (albums, tracks) = {
        let library = ui.core.library.borrow().clone();
        (library.albums.len(), library.tracks.len())
    };
    let plays = ui.core.db.scrobble_count().max(0) as u64;

    let (albums_col, albums_value) = stat_column(&group_thousands(albums as u64), "Albums");
    let (tracks_col, tracks_value) = stat_column(&group_thousands(tracks as u64), "Tracks");
    let (plays_col, plays_value) = stat_column(&group_thousands(plays), "Plays");

    let stats = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    stats.add_css_class("flaccy-hero-stats");
    stats.append(&albums_col);
    stats.append(&hero_divider());
    stats.append(&tracks_col);
    stats.append(&hero_divider());
    stats.append(&plays_col);
    hero.append(&stats);

    let hero_ui = Rc::clone(ui);
    ui.core.hub.subscribe_widget(&hero, move |_hero, event| {
        let changed = matches!(
            event,
            AppEvent::LibraryReloaded
                | AppEvent::ScanFinished { .. }
                | AppEvent::NaturalEnd(_)
                | AppEvent::HistoryImport { done: true, .. }
        );
        if !changed {
            return;
        }
        let library = hero_ui.core.library.borrow().clone();
        albums_value.set_label(&group_thousands(library.albums.len() as u64));
        tracks_value.set_label(&group_thousands(library.tracks.len() as u64));
        plays_value.set_label(&group_thousands(hero_ui.core.db.scrobble_count().max(0) as u64));
    });

    hero
}

fn hero_identity() -> gtk::Box {
    let glyph = gtk::Image::from_icon_name("audio-x-generic-symbolic");
    glyph.set_pixel_size(24);
    glyph.add_css_class("flaccy-hero-glyph");
    glyph.set_valign(gtk::Align::Center);

    let wordmark = gtk::Label::builder().label("flaccy").xalign(0.0).build();
    wordmark.add_css_class("flaccy-hero-title");
    let tagline = gtk::Label::builder()
        .label("Your lossless library")
        .xalign(0.0)
        .build();
    tagline.add_css_class("flaccy-hero-tagline");

    let labels = gtk::Box::new(gtk::Orientation::Vertical, 1);
    labels.set_valign(gtk::Align::Center);
    labels.append(&wordmark);
    labels.append(&tagline);

    let row = gtk::Box::new(gtk::Orientation::Horizontal, 14);
    row.append(&glyph);
    row.append(&labels);
    row
}

/// One dashboard column: a big count over a letterspaced caption. Returns the
/// value label so the count can be refreshed live.
fn stat_column(value: &str, caption: &str) -> (gtk::Box, gtk::Label) {
    let column = gtk::Box::new(gtk::Orientation::Vertical, 3);
    column.set_hexpand(true);
    column.set_halign(gtk::Align::Center);
    let value_label = gtk::Label::new(Some(value));
    value_label.add_css_class("stat-value");
    let caption_label = gtk::Label::new(Some(caption));
    caption_label.add_css_class("stat-caption");
    column.append(&value_label);
    column.append(&caption_label);
    (column, value_label)
}

fn hero_divider() -> gtk::Box {
    let divider = gtk::Box::new(gtk::Orientation::Vertical, 0);
    divider.add_css_class("flaccy-hero-divider");
    divider.set_valign(gtk::Align::Center);
    divider
}

/// Formats an integer with thousands separators (locale-agnostic commas), so
/// the dashboard reads "6,945" rather than "6945".
fn group_thousands(n: u64) -> String {
    let digits = n.to_string();
    let len = digits.len();
    let mut out = String::with_capacity(len + (len.saturating_sub(1)) / 3);
    for (i, ch) in digits.chars().enumerate() {
        if i > 0 && (len - i) % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    out
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
    group.add(&theme_row(ui));
    group
}

/// Theme picker: Adaptive (follows the playing album) plus curated palettes.
/// Applying is live — the whole app retints instantly via ThemeController.
fn theme_row(ui: &Rc<Ui>) -> adw::ComboRow {
    use crate::theme::Theme;
    let titles: Vec<&str> = Theme::ALL.iter().map(|t| t.title()).collect();
    let model = gtk::StringList::new(&titles);
    let row = adw::ComboRow::builder()
        .title("Theme")
        .subtitle("How Flaccy colors itself")
        .model(&model)
        .build();
    let current = Theme::from_id(&ui.core.config.borrow().theme);
    let selected = Theme::ALL.iter().position(|t| *t == current).unwrap_or(0);
    row.set_selected(selected as u32);
    row.set_subtitle(current.subtitle());

    let swatch = gtk::Box::new(gtk::Orientation::Vertical, 0);
    swatch.add_css_class("theme-swatch");
    swatch.set_valign(gtk::Align::Center);
    apply_swatch(&swatch, current);
    row.add_prefix(&swatch);
    {
        let ui = Rc::clone(ui);
        let swatch = swatch.clone();
        row.connect_selected_notify(move |row| {
            let theme = Theme::ALL
                .get(row.selected() as usize)
                .copied()
                .unwrap_or(Theme::Adaptive);
            row.set_subtitle(theme.subtitle());
            apply_swatch(&swatch, theme);
            ui.core.config.borrow_mut().theme = theme.id().to_string();
            ui.core.save_config();
            if let Some(controller) = crate::theme::ThemeController::current() {
                controller.set_theme(theme);
            }
            crate::logger::info("ui", &format!("theme set to {}", theme.id()));
        });
    }
    row
}

/// Swaps the `swatch-<id>` class so the picker's dot previews the theme color.
fn apply_swatch(swatch: &gtk::Box, theme: crate::theme::Theme) {
    for other in crate::theme::Theme::ALL {
        swatch.remove_css_class(&format!("swatch-{}", other.id()));
    }
    swatch.add_css_class(&format!("swatch-{}", theme.id()));
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

    let group_editions_row = adw::SwitchRow::builder()
        .title("Group Album Editions")
        .subtitle("Fold deluxe, remaster and explicit variants into one album; keep one best copy of each song")
        .active(ui.core.config.borrow().group_album_editions)
        .build();
    {
        let ui = Rc::clone(ui);
        group_editions_row.connect_active_notify(move |row| {
            ui.core.config.borrow_mut().group_album_editions = row.is_active();
            ui.core.save_config();
            crate::logger::info(
                "ui",
                &format!("group album editions set to {}", row.is_active()),
            );
            ui.core.reload_library();
        });
    }
    group.add(&group_editions_row);

    let rescan_row = adw::ActionRow::builder()
        .title("Rescan Library")
        .subtitle("Diff the folder against the database")
        .build();
    let rescan = gtk::Button::builder()
        .child(&adw::ButtonContent::builder().icon_name("view-refresh-symbolic").label("Rescan").build())
        .valign(gtk::Align::Center)
        .build();
    {
        let ui = Rc::clone(ui);
        rescan.connect_clicked(move |_| ui.core.rescan());
    }
    rescan_row.add_suffix(&rescan);
    group.add(&rescan_row);

    let artwork_row = adw::ActionRow::builder()
        .title("Find Missing Artwork")
        .subtitle("Re-fetch covers for albums that don't have one yet")
        .build();
    let artwork = gtk::Button::builder()
        .child(&adw::ButtonContent::builder().icon_name("image-x-generic-symbolic").label("Find Artwork").build())
        .valign(gtk::Align::Center)
        .build();
    {
        let ui = Rc::clone(ui);
        artwork.connect_clicked(move |btn| {
            let queued = ui.core.db.reset_missing_cover_retry();
            crate::enrichment::schedule_background_pass(&ui.core);
            btn.set_sensitive(false);
            ui.core.toast(&format!("Looking up artwork for {queued} albums…"));
        });
    }
    artwork_row.add_suffix(&artwork);
    group.add(&artwork_row);

    let cleanup_row = adw::ActionRow::builder()
        .title("Clean Up Library…")
        .subtitle("Trash duplicate files and merge album editions")
        .build();
    let cleanup = gtk::Button::builder()
        .child(&adw::ButtonContent::builder().icon_name("edit-clear-all-symbolic").label("Clean Up…").build())
        .valign(gtk::Align::Center)
        .build();
    cleanup.add_css_class("destructive-action");
    {
        let ui = Rc::clone(ui);
        cleanup.connect_clicked(move |_| crate::ui::cleanup::present(&ui));
    }
    cleanup_row.add_suffix(&cleanup);
    group.add(&cleanup_row);

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
