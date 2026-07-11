use crate::app::AppCore;
use crate::config;
use crate::events::AppEvent;
use crate::ui::{self, Ui};
use adw::prelude::*;
use gtk::glib;
use gtk::{gdk, gio};
use std::cell::RefCell;
use std::rc::Rc;

pub fn build(app: &adw::Application, core: &Rc<AppCore>) -> adw::ApplicationWindow {
    load_css();
    apply_color_scheme(&core.config.borrow().appearance);
    crate::theme::ThemeController::install(crate::theme::Theme::from_id(
        &core.config.borrow().theme,
    ));
    gtk::Window::set_default_icon_name("cc.midgarcorp.Flaccy");

    let (width, height) = {
        let config = core.config.borrow();
        (config.window_width.max(900), config.window_height.max(600))
    };
    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("Flaccy")
        .default_width(width)
        .default_height(height)
        .build();
    window.add_css_class("flaccy-window");

    let nav = adw::NavigationView::new();
    let ui = Rc::new(Ui {
        core: Rc::clone(core),
        nav: nav.clone(),
        window: window.clone(),
        query: Rc::new(RefCell::new(String::new())),
    });

    let header = adw::HeaderBar::builder()
        .title_widget(&adw::WindowTitle::new("Flaccy", ""))
        .build();

    let rescan_button = gtk::Button::from_icon_name("view-refresh-symbolic");
    rescan_button.set_tooltip_text(Some("Rescan Library"));
    {
        let core = Rc::clone(core);
        rescan_button.connect_clicked(move |_| core.rescan());
    }
    header.pack_start(&rescan_button);

    let enrich_spinner = gtk::Spinner::new();
    let enrich_label = gtk::Label::new(None);
    enrich_label.add_css_class("caption");
    enrich_label.add_css_class("dim");
    let enrich_box = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(6)
        .margin_start(4)
        .build();
    enrich_box.append(&enrich_spinner);
    enrich_box.append(&enrich_label);
    let enrich_revealer = gtk::Revealer::builder()
        .child(&enrich_box)
        .transition_type(gtk::RevealerTransitionType::SlideRight)
        .build();
    header.pack_start(&enrich_revealer);
    {
        let spinner = enrich_spinner.clone();
        let label = enrich_label.clone();
        core.hub.subscribe_widget(&enrich_revealer, move |revealer, event| {
            if let AppEvent::EnrichmentProgress { done, total } = event {
                if *total > 0 {
                    spinner.start();
                    label.set_text(&format!("Finding artwork… {done}/{total}"));
                    revealer.set_reveal_child(true);
                } else {
                    spinner.stop();
                    revealer.set_reveal_child(false);
                }
            }
        });
    }

    let menu = gio::Menu::new();
    menu.append(Some("Rescan Library"), Some("app.rescan"));
    menu.append(Some("Preferences"), Some("app.preferences"));
    menu.append(Some("About Flaccy"), Some("app.about"));
    menu.append(Some("Quit"), Some("app.quit"));
    let menu_button = gtk::MenuButton::builder()
        .icon_name("open-menu-symbolic")
        .menu_model(&menu)
        .build();
    header.pack_end(&menu_button);

    let search = gtk::SearchEntry::builder()
        .placeholder_text("Search")
        .width_request(220)
        .build();
    {
        let ui = Rc::clone(&ui);
        search.connect_search_changed(move |entry| {
            let text = entry.text().to_string();
            *ui.query.borrow_mut() = text.clone();
            ui.core.hub.emit(&AppEvent::SearchChanged(text));
        });
    }
    header.pack_end(&search);

    let progress = gtk::ProgressBar::builder().hexpand(true).build();
    progress.add_css_class("osd");
    let progress_revealer = gtk::Revealer::builder()
        .child(&progress)
        .transition_type(gtk::RevealerTransitionType::SlideDown)
        .build();
    {
        let progress = progress.clone();
        let rescan_button = rescan_button.clone();
        core.hub
            .subscribe_widget(&progress_revealer, move |revealer, event| match event {
                AppEvent::ScanStarted => {
                    progress.set_fraction(0.0);
                    revealer.set_reveal_child(true);
                    rescan_button.set_sensitive(false);
                    let spinner = gtk::Spinner::new();
                    spinner.start();
                    rescan_button.set_child(Some(&spinner));
                    rescan_button.set_tooltip_text(Some("Scanning…"));
                }
                AppEvent::ScanProgress(done, total) => {
                    if *total > 0 {
                        progress.set_fraction(*done as f64 / *total as f64);
                    } else {
                        progress.pulse();
                    }
                }
                AppEvent::ScanFinished { .. } => {
                    revealer.set_reveal_child(false);
                    rescan_button.set_sensitive(true);
                    rescan_button.set_icon_name("view-refresh-symbolic");
                    rescan_button.set_tooltip_text(Some("Rescan Library"));
                }
                _ => {}
            });
    }

    let stack = gtk::Stack::builder()
        .transition_type(gtk::StackTransitionType::Crossfade)
        .hexpand(true)
        .vexpand(true)
        .build();
    stack.add_named(&ui::albums::build(&ui), Some("albums"));
    stack.add_named(&ui::songs::build(&ui), Some("songs"));
    stack.add_named(&ui::artists::build(&ui), Some("artists"));
    stack.add_named(&ui::playlists::build(&ui), Some("playlists"));
    stack.add_named(&ui::stats::build(&ui), Some("stats"));
    stack.add_named(&ui::wantlist::build(&ui), Some("wantlist"));
    stack.add_named(&ui::guide::build(&ui), Some("guide"));

    let sidebar = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::Single)
        .width_request(200)
        .build();
    sidebar.add_css_class("navigation-sidebar");
    for (icon, label) in [
        ("media-optical-symbolic", "Albums"),
        ("audio-x-generic-symbolic", "Songs"),
        ("system-users-symbolic", "Artists"),
        ("view-list-symbolic", "Playlists"),
        ("flaccy-stats-symbolic", "Stats"),
        ("starred-symbolic", "Wantlist"),
        ("dialog-information-symbolic", "Guide"),
    ] {
        sidebar.append(&sidebar_row(icon, label));
    }
    attach_wantlist_badge(core, &sidebar);
    {
        let stack = stack.clone();
        let nav = nav.clone();
        let core_for_rows = Rc::clone(core);
        sidebar.connect_row_selected(move |_, row| {
            let Some(row) = row else { return };
            let names = [
                "albums", "songs", "artists", "playlists", "stats", "wantlist", "guide",
            ];
            let index = row.index().clamp(0, 6) as usize;
            core_for_rows.config.borrow_mut().sidebar_index = index as i32;
            core_for_rows.save_config();
            crate::logger::info("ui", &format!("sidebar selected: {}", names[index]));
            if nav.visible_page().and_then(|p| p.tag()).as_deref() != Some("root") {
                nav.pop_to_tag("root");
            }
            stack.set_visible_child_name(names[index]);
        });
    }
    {
        let sidebar = sidebar.clone();
        let saved_index = core.config.borrow().sidebar_index.clamp(0, 6);
        glib::idle_add_local_once(move || {
            let index = if config::demo_mode() {
                demo_start_view_index()
            } else {
                saved_index
            };
            if let Some(row) = sidebar.row_at_index(index) {
                sidebar.select_row(Some(&row));
                row.grab_focus();
            }
        });
    }

    let root_page = adw::NavigationPage::builder()
        .title("Flaccy")
        .tag("root")
        .child(&stack)
        .build();
    nav.add(&root_page);

    let content_box = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    let sidebar_scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&sidebar)
        .build();
    content_box.append(&sidebar_scroll);
    content_box.append(&gtk::Separator::new(gtk::Orientation::Vertical));
    content_box.append(&nav);

    let side_stack = gtk::Stack::builder()
        .transition_type(gtk::StackTransitionType::Crossfade)
        .build();
    side_stack.add_named(&ui::lyrics_panel::build(&ui), Some("lyrics"));
    side_stack.add_named(&ui::queue_panel::build(&ui), Some("queue"));

    let split = adw::OverlaySplitView::builder()
        .content(&content_box)
        .sidebar(&side_stack)
        .sidebar_position(gtk::PackType::End)
        .show_sidebar(false)
        .max_sidebar_width(400.0)
        .min_sidebar_width(320.0)
        .build();
    {
        let side_stack = side_stack.clone();
        let hub = Rc::clone(&core.hub);
        core.hub.subscribe_widget(&split, move |split, event| match event {
            AppEvent::LyricsToggled(show) => {
                if *show {
                    if side_stack.visible_child_name().as_deref() == Some("queue")
                        && split.shows_sidebar()
                    {
                        hub.emit(&AppEvent::QueueToggled(false));
                    }
                    side_stack.set_visible_child_name("lyrics");
                    split.set_show_sidebar(true);
                } else if side_stack.visible_child_name().as_deref() == Some("lyrics") {
                    split.set_show_sidebar(false);
                }
            }
            AppEvent::QueueToggled(show) => {
                if *show {
                    if side_stack.visible_child_name().as_deref() == Some("lyrics")
                        && split.shows_sidebar()
                    {
                        hub.emit(&AppEvent::LyricsToggled(false));
                    }
                    side_stack.set_visible_child_name("queue");
                    split.set_show_sidebar(true);
                } else if side_stack.visible_child_name().as_deref() == Some("queue") {
                    split.set_show_sidebar(false);
                }
            }
            _ => {}
        });
    }

    let inner = gtk::Box::new(gtk::Orientation::Vertical, 0);
    inner.append(&progress_revealer);
    inner.append(&split);

    let toast_overlay = adw::ToastOverlay::new();
    toast_overlay.set_child(Some(&inner));
    core.hub
        .subscribe_widget(&toast_overlay, |overlay, event| {
            if let AppEvent::Toast(message) = event {
                let toast = adw::Toast::new(message);
                toast.set_timeout(3);
                overlay.add_toast(toast);
            }
            if let AppEvent::ScanFinished { added, removed } = event {
                let toast = if *added > 0 || *removed > 0 {
                    let toast = adw::Toast::new(&format!(
                        "Library updated · {added} added · {removed} removed"
                    ));
                    toast.set_timeout(4);
                    toast
                } else {
                    let toast = adw::Toast::new("Library up to date");
                    toast.set_timeout(2);
                    toast
                };
                overlay.add_toast(toast);
            }
        });

    let toolbar_view = adw::ToolbarView::new();
    toolbar_view.add_top_bar(&header);
    toolbar_view.set_content(Some(&toast_overlay));
    toolbar_view.add_bottom_bar(&ui::transport::build(&ui));

    window.set_content(Some(&toolbar_view));

    register_actions(app, &ui, &search);
    attach_space_handler(&ui);
    attach_type_to_search(&ui, &search);
    attach_file_drop(&ui, &toast_overlay);
    schedule_demo_detail(&ui);

    {
        let core = Rc::clone(core);
        window.connect_close_request(move |window| {
            {
                let mut config = core.config.borrow_mut();
                config.window_width = window.width();
                config.window_height = window.height();
            }
            core.save_config();
            crate::logger::info("lifecycle", "window closed, config saved");
            glib::Propagation::Proceed
        });
    }

    window
}

/// Keeps an unseen-count badge on the Wantlist sidebar row, cleared when the
/// page is opened (WantlistSeen) and refreshed after every wantlist change.
fn attach_wantlist_badge(core: &Rc<AppCore>, sidebar: &gtk::ListBox) {
    let Some(row) = sidebar.row_at_index(5) else { return };
    let Some(row_box) = row.child().and_downcast::<gtk::Box>() else { return };
    let badge = gtk::Label::new(None);
    badge.add_css_class("wantlist-badge");
    badge.set_hexpand(true);
    badge.set_halign(gtk::Align::End);
    badge.set_visible(false);
    row_box.append(&badge);

    let update = {
        let core = Rc::clone(core);
        let badge = badge.clone();
        move || {
            let count = core.db.unseen_wanted_count();
            badge.set_visible(count > 0);
            if count > 0 {
                badge.set_label(&count.to_string());
            }
        }
    };
    update();
    core.hub.subscribe_widget(&badge, move |_, event| match event {
        AppEvent::WantlistChanged | AppEvent::WantlistSeen => update(),
        _ => {}
    });
}

fn sidebar_row(icon: &str, label: &str) -> gtk::ListBoxRow {
    let row_box = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .margin_top(8)
        .margin_bottom(8)
        .margin_start(6)
        .margin_end(6)
        .build();
    row_box.append(&gtk::Image::from_icon_name(icon));
    row_box.append(&gtk::Label::new(Some(label)));
    gtk::ListBoxRow::builder().child(&row_box).build()
}

fn register_actions(app: &adw::Application, ui: &Rc<Ui>, search: &gtk::SearchEntry) {
    let window = &ui.window;

    let rescan = gio::SimpleAction::new("rescan", None);
    {
        let core = Rc::clone(&ui.core);
        rescan.connect_activate(move |_, _| core.rescan());
    }
    app.add_action(&rescan);

    let preferences = gio::SimpleAction::new("preferences", None);
    {
        let ui = Rc::clone(ui);
        preferences.connect_activate(move |_, _| ui::prefs::present(&ui));
    }
    app.add_action(&preferences);

    let about = gio::SimpleAction::new("about", None);
    {
        let window = window.clone();
        about.connect_activate(move |_, _| {
            let dialog = adw::AboutDialog::builder()
                .application_name("Flaccy")
                .application_icon("cc.midgarcorp.Flaccy")
                .developer_name("Midgar Oy")
                .version(env!("CARGO_PKG_VERSION"))
                .comments("Lossless music player. Last.fm connected. Gapless.")
                .website("https://midgarcorp.cc/flaccy")
                .build();
            dialog.present(Some(&window));
        });
    }
    app.add_action(&about);

    let quit = gio::SimpleAction::new("quit", None);
    {
        let app = app.clone();
        quit.connect_activate(move |_, _| app.quit());
    }
    app.add_action(&quit);

    let focus_search = gio::SimpleAction::new("focus-search", None);
    {
        let search = search.clone();
        focus_search.connect_activate(move |_, _| {
            search.grab_focus();
        });
    }
    ui.window.add_action(&focus_search);

    app.set_accels_for_action("win.focus-search", &["<Control>f"]);
    app.set_accels_for_action("app.preferences", &["<Control>comma"]);
    app.set_accels_for_action("app.quit", &["<Control>q"]);

    add_string_action(ui, "play-album", |ui, key| {
        ui.core.play_album_key(key, false);
    });
    add_string_action(ui, "shuffle-album", |ui, key| {
        ui.core.play_album_key(key, true);
    });
    add_string_action(ui, "album-play-next", |ui, key| {
        let library = ui.core.library.borrow().clone();
        if let Some(album) = library.album_by_key(key) {
            for track in album.tracks.iter().rev() {
                ui.core.player.insert_next(track.clone());
            }
        }
    });
    add_string_action(ui, "album-queue", |ui, key| {
        let library = ui.core.library.borrow().clone();
        if let Some(album) = library.album_by_key(key) {
            for track in &album.tracks {
                ui.core.player.add_to_queue(track.clone());
            }
        }
    });
    add_string_action(ui, "track-play-next", |ui, rel| {
        let library = ui.core.library.borrow().clone();
        if let Some(track) = library.track_by_rel_path(rel) {
            ui.core.player.insert_next(track.clone());
        }
    });
    add_string_action(ui, "track-queue", |ui, rel| {
        let library = ui.core.library.borrow().clone();
        if let Some(track) = library.track_by_rel_path(rel) {
            ui.core.player.add_to_queue(track.clone());
        }
    });
    add_string_action(ui, "track-love", |ui, rel| {
        ui.core.toggle_love(rel);
    });
    add_string_action(ui, "track-station", |ui, rel| {
        ui.core.start_track_station(rel);
    });
    add_string_action(ui, "artist-station", |ui, artist| {
        ui.core.start_artist_station(artist);
    });
    add_string_action(ui, "artist-play", |ui, artist| {
        ui.core.play_artist(artist, false);
    });
    add_string_action(ui, "artist-shuffle", |ui, artist| {
        ui.core.play_artist(artist, true);
    });
    add_string_action(ui, "track-songlink", |ui, rel| {
        let library = ui.core.library.borrow().clone();
        if let Some(track) = library.track_by_rel_path(rel) {
            crate::songlink::copy_link(&ui.core, track.title.clone(), track.artist.clone(), false);
        }
    });
    add_string_action(ui, "album-songlink", |ui, key| {
        let library = ui.core.library.borrow().clone();
        if let Some(album) = library.album_by_key(key) {
            crate::songlink::copy_link(&ui.core, album.title.clone(), album.artist.clone(), true);
        }
    });
    add_string_action(ui, "album-enrich", |ui, key| {
        let library = ui.core.library.borrow().clone();
        let Some(album) = library.album_by_key(key) else { return };
        let complete = ui
            .core
            .db
            .album_info_status(&album.title, &album.artist)
            .map(|s| s.year.is_some() && s.genre.is_some() && s.has_cover)
            .unwrap_or(false);
        if complete {
            ui.core.toast("Metadata already complete");
            return;
        }
        crate::enrichment::request_album(&ui.core, &album.title, &album.artist);
        ui.core.toast(&format!("Enriching {}…", album.title));
    });
    add_string_action(ui, "album-station", |ui, key| {
        let library = ui.core.library.borrow().clone();
        if let Some(album) = library.album_by_key(key) {
            ui.core.start_artist_station(&album.artist.clone());
        }
    });

    let sleep_minutes = gio::SimpleAction::new("sleep-minutes", Some(glib::VariantTy::INT32));
    {
        let core = Rc::clone(&ui.core);
        sleep_minutes.connect_activate(move |_, parameter| {
            if let Some(minutes) = parameter.and_then(|v| v.get::<i32>()) {
                core.set_sleep_timer_minutes(minutes as i64);
            }
        });
    }
    app.add_action(&sleep_minutes);

    let sleep_eot = gio::SimpleAction::new("sleep-end-of-track", None);
    {
        let core = Rc::clone(&ui.core);
        sleep_eot.connect_activate(move |_, _| core.set_sleep_timer_end_of_track());
    }
    app.add_action(&sleep_eot);

    let sleep_cancel = gio::SimpleAction::new("sleep-cancel", None);
    {
        let core = Rc::clone(&ui.core);
        sleep_cancel.connect_activate(move |_, _| core.cancel_sleep_timer());
    }
    app.add_action(&sleep_cancel);

    let next_track = gio::SimpleAction::new("next-track", None);
    {
        let core = Rc::clone(&ui.core);
        next_track.connect_activate(move |_, _| {
            core.next();
        });
    }
    app.add_action(&next_track);

    let previous_track = gio::SimpleAction::new("previous-track", None);
    {
        let core = Rc::clone(&ui.core);
        previous_track.connect_activate(move |_, _| core.previous());
    }
    app.add_action(&previous_track);

    let love_current = gio::SimpleAction::new("love-current", None);
    {
        let core = Rc::clone(&ui.core);
        love_current.connect_activate(move |_, _| {
            if let Some(track) = core.player.current_track() {
                core.toggle_love(&track.rel_path);
            }
        });
    }
    app.add_action(&love_current);

    let shortcuts = gio::SimpleAction::new("shortcuts", None);
    {
        let window = ui.window.clone();
        shortcuts.connect_activate(move |_, _| present_shortcuts(&window));
    }
    app.add_action(&shortcuts);

    app.set_accels_for_action("app.next-track", &["<Control>Right"]);
    app.set_accels_for_action("app.previous-track", &["<Control>Left"]);
    app.set_accels_for_action("app.love-current", &["<Control>l"]);
    app.set_accels_for_action("app.shortcuts", &["<Control>question"]);
    add_string_action(ui, "playlist-new-with-track", |ui, rel| {
        ui::playlists::prompt_new_playlist(ui, Some(rel.to_string()));
    });

    let playlist_add = gio::SimpleAction::new(
        "playlist-add",
        Some(&glib::VariantTy::new("(xs)").expect("valid variant type")),
    );
    {
        let ui = Rc::clone(ui);
        playlist_add.connect_activate(move |_, parameter| {
            let Some((playlist_id, rel)) = parameter.and_then(|v| v.get::<(i64, String)>()) else {
                return;
            };
            if let Err(err) = ui.core.db.add_track_to_playlist(playlist_id, &rel) {
                crate::logger::error("database", &format!("playlist add failed: {err}"));
            }
            ui.core.hub.emit(&AppEvent::LibraryReloaded);
        });
    }
    ui.window.add_action(&playlist_add);

    let playlist_remove = gio::SimpleAction::new(
        "playlist-remove-row",
        Some(&glib::VariantTy::new("(xx)").expect("valid variant type")),
    );
    {
        let ui = Rc::clone(ui);
        playlist_remove.connect_activate(move |_, parameter| {
            let Some((_, row_id)) = parameter.and_then(|v| v.get::<(i64, i64)>()) else {
                return;
            };
            if let Err(err) = ui.core.db.remove_playlist_track(row_id) {
                crate::logger::error("database", &format!("playlist remove failed: {err}"));
            }
            ui.core.hub.emit(&AppEvent::LibraryReloaded);
        });
    }
    ui.window.add_action(&playlist_remove);

    add_int64_action(ui, "playlist-play", |ui, id| {
        ui::playlists::play_playlist(ui, id, false);
    });
    add_int64_action(ui, "playlist-shuffle", |ui, id| {
        ui::playlists::play_playlist(ui, id, true);
    });
    add_int64_action(ui, "playlist-rename", |ui, id| {
        ui::playlists::prompt_rename_playlist(ui, id);
    });
    add_int64_action(ui, "playlist-delete", |ui, id| {
        ui::playlists::confirm_delete_playlist(ui, id);
    });
}

/// Accepts audio files/folders dropped anywhere on the window: copies them
/// into the library root and rescans.
fn attach_file_drop(ui: &Rc<Ui>, host: &impl IsA<gtk::Widget>) {
    let drop = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY);
    let ui = Rc::clone(ui);
    drop.connect_drop(move |_, value, _, _| {
        let Ok(files) = value.get::<gdk::FileList>() else { return false };
        let paths: Vec<std::path::PathBuf> =
            files.files().iter().filter_map(|f| f.path()).collect();
        if paths.is_empty() {
            return false;
        }
        crate::logger::info(
            "library",
            &format!("drag-drop received {} item(s)", paths.len()),
        );
        ui.core.import_dropped_paths(paths);
        true
    });
    host.add_controller(drop);
}

fn present_shortcuts(window: &adw::ApplicationWindow) {
    let groups: [(&str, &[(&str, &str)]); 2] = [
        (
            "Playback",
            &[
                ("Space", "Play / Pause"),
                ("Ctrl+→", "Next track"),
                ("Ctrl+←", "Previous track"),
                ("Ctrl+L", "Love current track"),
            ],
        ),
        (
            "Library",
            &[
                ("Ctrl+F", "Search"),
                ("Ctrl+,", "Preferences"),
                ("Ctrl+?", "Keyboard shortcuts"),
                ("Ctrl+Q", "Quit"),
            ],
        ),
    ];
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .margin_top(20)
        .margin_bottom(24)
        .margin_start(24)
        .margin_end(24)
        .build();
    for (title, entries) in groups {
        let section = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let heading = gtk::Label::builder().label(title).xalign(0.0).build();
        heading.add_css_class("heading");
        section.append(&heading);
        for (accel, description) in entries {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 16);
            let description_label = gtk::Label::builder()
                .label(*description)
                .xalign(0.0)
                .hexpand(true)
                .build();
            row.append(&description_label);
            let accel_label = gtk::Label::new(Some(accel));
            accel_label.add_css_class("keycap");
            row.append(&accel_label);
            section.append(&row);
        }
        content.append(&section);
    }
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(
        &adw::HeaderBar::builder()
            .title_widget(&adw::WindowTitle::new("Keyboard Shortcuts", ""))
            .build(),
    );
    toolbar.set_content(Some(&content));
    let dialog = adw::Dialog::builder()
        .content_width(420)
        .child(&toolbar)
        .build();
    dialog.present(Some(window));
}

fn add_string_action(ui: &Rc<Ui>, name: &str, handler: impl Fn(&Rc<Ui>, &str) + 'static) {
    let action = gio::SimpleAction::new(name, Some(glib::VariantTy::STRING));
    let ui_for_handler = Rc::clone(ui);
    action.connect_activate(move |_, parameter| {
        if let Some(value) = parameter.and_then(|v| v.get::<String>()) {
            handler(&ui_for_handler, &value);
        }
    });
    ui.window.add_action(&action);
}

fn add_int64_action(ui: &Rc<Ui>, name: &str, handler: impl Fn(&Rc<Ui>, i64) + 'static) {
    let action = gio::SimpleAction::new(name, Some(glib::VariantTy::INT64));
    let ui_for_handler = Rc::clone(ui);
    action.connect_activate(move |_, parameter| {
        if let Some(value) = parameter.and_then(|v| v.get::<i64>()) {
            handler(&ui_for_handler, value);
        }
    });
    ui.window.add_action(&action);
}

/// Type-to-search: pressing a printable key while a list/grid view (not a text
/// field) has focus jumps into the header search and filters the current view.
/// Runs in the capture phase so it beats the views' own type-ahead; Space is
/// left to the play/pause handler, and modifier combos fall through to
/// accelerators.
fn attach_type_to_search(ui: &Rc<Ui>, search: &gtk::SearchEntry) {
    let controller = gtk::EventControllerKey::new();
    controller.set_propagation_phase(gtk::PropagationPhase::Capture);
    let key_window = ui.window.clone();
    let key_search = search.clone();
    controller.connect_key_pressed(move |_, key, _, modifiers| {
        let editing = gtk::prelude::GtkWindowExt::focus(&key_window)
            .map(|widget| widget.is::<gtk::Text>() || widget.is::<gtk::Entry>())
            .unwrap_or(false);
        if editing {
            return glib::Propagation::Proceed;
        }
        if modifiers.intersects(
            gdk::ModifierType::CONTROL_MASK | gdk::ModifierType::ALT_MASK | gdk::ModifierType::SUPER_MASK,
        ) {
            return glib::Propagation::Proceed;
        }
        let Some(ch) = key.to_unicode() else {
            return glib::Propagation::Proceed;
        };
        if ch.is_control() || ch.is_whitespace() {
            return glib::Propagation::Proceed;
        }
        key_search.grab_focus();
        let mut text = key_search.text().to_string();
        text.push(ch);
        key_search.set_text(&text);
        key_search.set_position(-1);
        glib::Propagation::Stop
    });
    ui.window.add_controller(controller);

    let stop_window = ui.window.clone();
    search.connect_stop_search(move |entry| {
        entry.set_text("");
        gtk::prelude::GtkWindowExt::set_focus(&stop_window, gtk::Widget::NONE);
    });
}

fn attach_space_handler(ui: &Rc<Ui>) {
    let controller = gtk::EventControllerKey::new();
    let ui_ref = Rc::clone(ui);
    controller.connect_key_pressed(move |_, key, _, _| {
        if key == gdk::Key::space {
            let editing = gtk::prelude::GtkWindowExt::focus(&ui_ref.window)
                .map(|widget| widget.is::<gtk::Text>() || widget.is::<gtk::Entry>())
                .unwrap_or(false);
            if !editing {
                ui_ref.core.toggle_play_pause();
                return glib::Propagation::Stop;
            }
        }
        glib::Propagation::Proceed
    });
    ui.window.add_controller(controller);
}

pub fn apply_color_scheme(appearance: &str) {
    let scheme = match appearance {
        "light" => adw::ColorScheme::ForceLight,
        "dark" => adw::ColorScheme::ForceDark,
        _ => adw::ColorScheme::Default,
    };
    adw::StyleManager::default().set_color_scheme(scheme);
}

fn load_css() {
    let provider = gtk::CssProvider::new();
    provider.load_from_string(include_str!("style.css"));
    if let Some(display) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
}

/// Demo mode helper: FLACCY_DEMO_DETAIL pushes the named album's detail page
/// once the library is loaded, so marketing screenshots can show album detail
/// without input automation.
fn schedule_demo_detail(ui: &Rc<Ui>) {
    if !config::demo_mode() {
        return;
    }
    if let Some(wanted) = std::env::var("FLACCY_DEMO_DETAIL").ok() {
        let ui = Rc::clone(ui);
        glib::timeout_add_local(std::time::Duration::from_millis(700), move || {
            let library = ui.core.library.borrow().clone();
            let Some(album) = library.albums.iter().find(|a| a.title == wanted).cloned() else {
                return glib::ControlFlow::Continue;
            };
            crate::ui::albums::push_album_detail(&ui, &album);
            glib::ControlFlow::Break
        });
    }
    if let Some(artist) = std::env::var("FLACCY_DEMO_ARTIST").ok() {
        let ui = Rc::clone(ui);
        glib::timeout_add_local(std::time::Duration::from_millis(700), move || {
            let library = ui.core.library.borrow().clone();
            if !library.artists.iter().any(|a| a.name == artist) {
                return glib::ControlFlow::Continue;
            }
            crate::ui::artists::push_artist_page(&ui, &artist);
            glib::ControlFlow::Break
        });
    }
    if std::env::var_os("FLACCY_DEMO_LYRICS").is_some() {
        let ui = Rc::clone(ui);
        glib::timeout_add_local_once(std::time::Duration::from_millis(1400), move || {
            ui.core.hub.emit(&AppEvent::LyricsToggled(true));
        });
    }
    if std::env::var_os("FLACCY_DEMO_PREFS").is_some() {
        let ui = Rc::clone(ui);
        glib::timeout_add_local_once(std::time::Duration::from_millis(1400), move || {
            ui::prefs::present(&ui);
        });
    }
}

/// Demo mode helper: FLACCY_DEMO_VIEW picks the initially selected sidebar view
/// (albums, songs, artists, playlists, stats) so marketing screenshots can be
/// captured without input automation. Defaults to albums.
fn demo_start_view_index() -> i32 {
    match std::env::var("FLACCY_DEMO_VIEW").ok().as_deref() {
        Some("songs") => 1,
        Some("artists") => 2,
        Some("playlists") => 3,
        Some("stats") => 4,
        Some("wantlist") => 5,
        Some("guide") => 6,
        _ => 0,
    }
}
