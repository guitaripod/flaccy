use crate::app::AppCore;
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

    let sidebar = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::Single)
        .width_request(200)
        .build();
    sidebar.add_css_class("navigation-sidebar");
    for (icon, label) in [
        ("media-optical-symbolic", "Albums"),
        ("emblem-music-symbolic", "Songs"),
        ("system-users-symbolic", "Artists"),
        ("view-list-symbolic", "Playlists"),
        ("utilities-system-monitor-symbolic", "Stats"),
    ] {
        sidebar.append(&sidebar_row(icon, label));
    }
    {
        let stack = stack.clone();
        let nav = nav.clone();
        sidebar.connect_row_selected(move |_, row| {
            let Some(row) = row else { return };
            let names = ["albums", "songs", "artists", "playlists", "stats"];
            let index = row.index().clamp(0, 4) as usize;
            crate::logger::info("ui", &format!("sidebar selected: {}", names[index]));
            if nav.visible_page().and_then(|p| p.tag()).as_deref() != Some("root") {
                nav.pop_to_tag("root");
            }
            stack.set_visible_child_name(names[index]);
        });
    }
    {
        let sidebar = sidebar.clone();
        glib::idle_add_local_once(move || {
            if let Some(first) = sidebar.row_at_index(0) {
                sidebar.select_row(Some(&first));
                first.grab_focus();
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

    let split = adw::OverlaySplitView::builder()
        .content(&content_box)
        .sidebar(&ui::lyrics_panel::build(&ui))
        .sidebar_position(gtk::PackType::End)
        .show_sidebar(false)
        .max_sidebar_width(400.0)
        .min_sidebar_width(320.0)
        .build();
    {
        core.hub.subscribe_widget(&split, |split, event| {
            if let AppEvent::LyricsToggled(show) = event {
                if split.shows_sidebar() != *show {
                    split.set_show_sidebar(*show);
                }
            }
        });
    }

    let inner = gtk::Box::new(gtk::Orientation::Vertical, 0);
    inner.append(&progress_revealer);
    inner.append(&split);

    let toast_overlay = adw::ToastOverlay::new();
    toast_overlay.set_child(Some(&inner));
    core.hub
        .subscribe_widget(&toast_overlay, |overlay, event| {
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
