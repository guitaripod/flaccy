use crate::events::AppEvent;
use crate::library::{format_time, Album};
use crate::ui::{context, Ui};
use adw::prelude::*;
use gtk::glib::BoxedAnyObject;
use gtk::{gdk, gio, glib, pango};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let store = gio::ListStore::new::<BoxedAnyObject>();

    let filter = {
        let query = Rc::clone(&ui.query);
        gtk::CustomFilter::new(move |obj| {
            let Some(boxed) = obj.downcast_ref::<BoxedAnyObject>() else {
                return true;
            };
            let query = query.borrow();
            if query.is_empty() {
                return true;
            }
            let needle = query.to_lowercase();
            let album = boxed.borrow::<Album>();
            album.title.to_lowercase().contains(&needle)
                || album.artist.to_lowercase().contains(&needle)
        })
    };
    let filter_model = gtk::FilterListModel::new(Some(store.clone()), Some(filter.clone()));
    let selection = gtk::NoSelection::new(Some(filter_model));

    let bound: Rc<RefCell<HashMap<String, glib::WeakRef<gtk::Picture>>>> =
        Rc::new(RefCell::new(HashMap::new()));

    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(move |_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let cell = build_album_cell();
        let gesture = gtk::GestureClick::builder().button(gdk::BUTTON_SECONDARY).build();
        let item_weak = item.downgrade();
        let anchor = cell.clone();
        gesture.connect_pressed(move |_, _, x, y| {
            let Some(item) = item_weak.upgrade() else { return };
            let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() else {
                return;
            };
            let key = boxed.borrow::<Album>().key();
            context::popup_menu_at(&anchor, &context::album_menu(&key), x, y);
        });
        cell.add_controller(gesture);
        item.set_child(Some(&cell));
    });
    {
        let ui = Rc::clone(ui);
        let bound = Rc::clone(&bound);
        factory.connect_bind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let Some(cell) = item.child() else { return };
            let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() else {
                return;
            };
            let album = boxed.borrow::<Album>();
            let Some(picture) = cell.first_child().and_downcast::<gtk::Picture>() else {
                return;
            };
            let Some(title) = picture.next_sibling().and_downcast::<gtk::Label>() else {
                return;
            };
            let Some(subtitle) = title.next_sibling().and_downcast::<gtk::Label>() else {
                return;
            };
            title.set_label(&album.title);
            title.set_tooltip_text(Some(&album.title));
            subtitle.set_label(&subtitle_text(&album));
            picture.set_paintable(Some(&ui.core.artwork.placeholder(&album.key())));
            let expected = album.key();
            let item_weak = item.downgrade();
            let weak = picture.downgrade();
            ui.core.artwork.request(&album.title, &album.artist, 168, move |texture, _| {
                if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                    if still_bound_album(&item_weak, &expected) {
                        picture.set_paintable(Some(texture));
                    }
                }
            });
            bound.borrow_mut().insert(album.key(), picture.downgrade());
        });
    }
    {
        let bound = Rc::clone(&bound);
        factory.connect_unbind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            if let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() {
                bound.borrow_mut().remove(&boxed.borrow::<Album>().key());
            }
        });
    }

    let grid = gtk::GridView::builder()
        .model(&selection)
        .factory(&factory)
        .min_columns(2)
        .max_columns(10)
        .single_click_activate(true)
        .margin_top(24)
        .margin_bottom(24)
        .margin_start(24)
        .margin_end(24)
        .build();
    grid.add_css_class("album-grid");
    {
        let ui = Rc::clone(ui);
        grid.connect_activate(move |grid, position| {
            let Some(boxed) = grid
                .model()
                .and_then(|model| model.item(position))
                .and_downcast::<BoxedAnyObject>()
            else {
                return;
            };
            let album = boxed.borrow::<Album>().clone();
            push_album_detail(&ui, &album);
        });
    }

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(&grid)
        .build();
    let grid_content = gtk::Box::new(gtk::Orientation::Vertical, 0);
    grid_content.append(&crate::ui::suggested_shelf::build(ui));
    grid_content.append(&scroll);

    let empty = adw::StatusPage::builder()
        .icon_name("audio-x-generic-symbolic")
        .title("No Music Found")
        .description("Drop FLAC or MP3 files into your music folder, then rescan.\nChoose a different folder in Preferences.")
        .build();
    let empty_actions = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .halign(gtk::Align::Center)
        .build();
    let empty_button = gtk::Button::with_label("Choose Music Folder");
    empty_button.add_css_class("pill");
    empty_button.add_css_class("suggested-action");
    empty_button.set_action_name(Some("app.preferences"));
    empty_actions.append(&empty_button);
    let sample_button = gtk::Button::with_label("Download Sample Album");
    sample_button.add_css_class("pill");
    {
        let ui = Rc::clone(ui);
        sample_button.connect_clicked(move |_| crate::samples::download(&ui.core));
    }
    empty_actions.append(&sample_button);
    let sample_progress = gtk::Label::new(None);
    sample_progress.add_css_class("dim");
    sample_progress.add_css_class("caption");
    sample_progress.set_visible(false);
    empty_actions.append(&sample_progress);
    {
        let sample_button = sample_button.clone();
        let sample_progress_ref = sample_progress.clone();
        ui.core
            .hub
            .subscribe_widget(&empty_actions, move |_, event| {
                if let AppEvent::SampleDownload { text, done, failed } = event {
                    sample_progress_ref.set_visible(true);
                    sample_progress_ref.set_label(text);
                    sample_button.set_sensitive(*done);
                    if *done && !failed {
                        sample_button.set_label("Sample Album Added");
                    }
                }
            });
    }
    empty.set_child(Some(&empty_actions));

    let stack = gtk::Stack::new();
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&grid_content, Some("grid"));

    let rebuild = {
        let store = store.clone();
        let stack = stack.clone();
        let scroll = scroll.clone();
        let ui = Rc::clone(ui);
        let applied = Cell::new(0u64);
        move || {
            let library = ui.core.library.borrow().clone();
            let fingerprint = albums_fingerprint(&library.albums);
            if applied.replace(fingerprint) != fingerprint {
                let saved = scroll.vadjustment().value();
                let items: Vec<BoxedAnyObject> = library
                    .albums
                    .iter()
                    .map(|album| BoxedAnyObject::new(album.clone()))
                    .collect();
                store.splice(0, store.n_items(), &items);
                if saved > 0.0 {
                    let adj = scroll.vadjustment();
                    glib::idle_add_local_once(move || adj.set_value(saved));
                }
            }
            stack.set_visible_child_name(if library.albums.is_empty() {
                "empty"
            } else {
                "grid"
            });
        }
    };
    rebuild();

    {
        let rebuild = rebuild.clone();
        let filter = filter.clone();
        ui.core.hub.subscribe_widget(&stack, move |_, event| match event {
            AppEvent::LibraryReloaded => rebuild(),
            AppEvent::SearchChanged(_) => filter.changed(gtk::FilterChange::Different),
            _ => {}
        });
    }

    {
        let ui = Rc::clone(ui);
        let bound = Rc::clone(&bound);
        ui.core.hub.clone().subscribe_widget(&stack, move |_, event| {
            if let AppEvent::AlbumEnriched { title, artist } = event {
                ui.core.artwork.invalidate(title, artist);
                let key = format!("{title}|{artist}");
                let picture = bound.borrow().get(&key).and_then(|w| w.upgrade());
                if let Some(picture) = picture {
                    let weak = picture.downgrade();
                    let bound = Rc::clone(&bound);
                    ui.core.artwork.request(title, artist, 168, move |texture, _| {
                        if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                            let still = bound
                                .borrow()
                                .get(&key)
                                .and_then(|w| w.upgrade())
                                .is_some_and(|current| current == picture);
                            if still {
                                picture.set_paintable(Some(texture));
                            }
                        }
                    });
                }
            }
        });
    }

    stack.upcast()
}

/// Digest of the album set plus the metadata the grid renders; any add,
/// removal, reorder, or enriched year/genre changes it, triggering a model
/// splice (the virtualized GridView only rebinds the handful of visible cells).
fn albums_fingerprint(albums: &[Album]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for album in albums {
        let row = format!("{}|{}|{:?}|{:?}", album.title, album.artist, album.year, album.genre);
        hash = hash.rotate_left(5) ^ crate::palette::fnv1a_64(&row);
    }
    hash
}

fn subtitle_text(album: &Album) -> String {
    match &album.year {
        Some(year) if !year.is_empty() => format!("{} · {}", album.artist, year),
        _ => album.artist.clone(),
    }
}

/// Guards an async artwork callback against GridView cell recycling: the shared
/// tile widget may have been rebound to a different album by the time a queued
/// cover decode lands, so only paint if the list item still holds this album.
fn still_bound_album(item: &glib::WeakRef<gtk::ListItem>, expected: &str) -> bool {
    item.upgrade()
        .and_then(|item| item.item())
        .and_downcast::<BoxedAnyObject>()
        .is_some_and(|boxed| boxed.borrow::<Album>().key() == expected)
}

/// Empty tile shell reused by the GridView factory: cover picture, title, and
/// subtitle in fixed order (the bind step fills them and requests artwork).
fn build_album_cell() -> gtk::Box {
    let cell = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .width_request(168)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Start)
        .build();
    cell.add_css_class("album-tile");

    let picture = gtk::Picture::builder()
        .width_request(168)
        .height_request(168)
        .content_fit(gtk::ContentFit::Cover)
        .build();
    picture.set_overflow(gtk::Overflow::Hidden);
    picture.add_css_class("cover");
    cell.append(&picture);

    let title = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(18)
        .build();
    title.add_css_class("album-title");
    cell.append(&title);

    let subtitle = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(20)
        .build();
    subtitle.add_css_class("dim");
    subtitle.add_css_class("caption");
    cell.append(&subtitle);

    cell
}

pub fn push_album_detail(ui: &Rc<Ui>, album: &Album) {
    let dominant: Rc<RefCell<Option<(u8, u8, u8)>>> = Rc::new(RefCell::new(None));

    let backdrop = gtk::DrawingArea::new();
    backdrop.set_hexpand(true);
    backdrop.set_vexpand(true);
    {
        let dominant = Rc::clone(&dominant);
        backdrop.set_draw_func(move |_, cr, width, height| {
            let Some((r, g, b)) = *dominant.borrow() else { return };
            let dark = adw::StyleManager::default().is_dark();
            let blend = |channel: u8| {
                let value = channel as f64 / 255.0;
                if dark {
                    value * 0.55
                } else {
                    value * 0.45 + 0.98 * 0.55
                }
            };
            let (r, g, b) = (blend(r), blend(g), blend(b));
            let gradient = gtk::cairo::LinearGradient::new(0.0, 0.0, 0.0, height as f64);
            gradient.add_color_stop_rgba(0.0, r, g, b, 0.85);
            gradient.add_color_stop_rgba(0.7, r, g, b, 0.0);
            let _ = cr.set_source(&gradient);
            cr.rectangle(0.0, 0.0, width as f64, height as f64);
            let _ = cr.fill();
        });
    }
    {
        let weak = backdrop.downgrade();
        adw::StyleManager::default().connect_dark_notify(move |_| {
            if let Some(backdrop) = weak.upgrade() {
                backdrop.queue_draw();
            }
        });
    }

    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(24)
        .build();

    let picture = gtk::Picture::builder()
        .width_request(232)
        .height_request(232)
        .content_fit(gtk::ContentFit::Cover)
        .valign(gtk::Align::Start)
        .build();
    picture.set_overflow(gtk::Overflow::Hidden);
    picture.add_css_class("cover-large");
    picture.set_paintable(Some(&ui.core.artwork.placeholder(&album.key())));
    {
        let weak = picture.downgrade();
        let backdrop_weak = backdrop.downgrade();
        let dominant = Rc::clone(&dominant);
        ui.core
            .artwork
            .request(&album.title, &album.artist, 232, move |texture, color| {
                if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                    picture.set_paintable(Some(texture));
                }
                if let Some(color) = color {
                    *dominant.borrow_mut() = Some(color);
                    if let Some(backdrop) = backdrop_weak.upgrade() {
                        backdrop.queue_draw();
                    }
                }
            });
    }
    header.append(&picture);

    let meta = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(6)
        .valign(gtk::Align::Center)
        .build();
    let title = gtk::Label::builder()
        .label(&album.title)
        .xalign(0.0)
        .wrap(true)
        .build();
    title.add_css_class("title-1");
    meta.append(&title);
    let artist = gtk::Label::builder().label(&album.artist).xalign(0.0).build();
    artist.add_css_class("title-4");
    artist.add_css_class("dim");
    meta.append(&artist);

    let info_text = |year: Option<&String>, genre: Option<&String>| {
        let mut info_parts: Vec<String> = Vec::new();
        if let Some(year) = year.filter(|y| !y.is_empty()) {
            info_parts.push(year.clone());
        }
        if let Some(genre) = genre.filter(|g| !g.is_empty()) {
            info_parts.push(genre.clone());
        }
        info_parts.push(format!(
            "{} songs · {} min",
            album.tracks.len(),
            (album.total_duration() / 60.0).round() as i64
        ));
        info_parts.join(" · ")
    };
    let info = gtk::Label::builder()
        .label(info_text(album.year.as_ref(), album.genre.as_ref()))
        .xalign(0.0)
        .build();
    info.add_css_class("dim");
    info.add_css_class("caption");
    meta.append(&info);

    let playcount = gtk::Label::builder().xalign(0.0).visible(false).build();
    playcount.add_css_class("dim");
    playcount.add_css_class("caption");
    meta.append(&playcount);
    load_user_playcount(ui, album, &playcount);

    crate::enrichment::request_album(&ui.core, &album.title, &album.artist);
    {
        let ui_ref = Rc::clone(ui);
        let album_title = album.title.clone();
        let album_artist = album.artist.clone();
        let picture_weak = picture.downgrade();
        let backdrop_weak = backdrop.downgrade();
        let dominant_ref = Rc::clone(&dominant);
        let info_for = {
            let album = album.clone();
            move |year: Option<&String>, genre: Option<&String>| {
                let mut info_parts: Vec<String> = Vec::new();
                if let Some(year) = year.filter(|y| !y.is_empty()) {
                    info_parts.push(year.clone());
                }
                if let Some(genre) = genre.filter(|g| !g.is_empty()) {
                    info_parts.push(genre.clone());
                }
                info_parts.push(format!(
                    "{} songs · {} min",
                    album.tracks.len(),
                    (album.total_duration() / 60.0).round() as i64
                ));
                info_parts.join(" · ")
            }
        };
        ui.core.hub.subscribe_widget(&info, move |info, event| {
            let AppEvent::AlbumEnriched { title, artist } = event else { return };
            if title != &album_title || artist != &album_artist {
                return;
            }
            if let Some(status) = ui_ref.core.db.album_info_status(title, artist) {
                info.set_label(&info_for(status.year.as_ref(), status.genre.as_ref()));
            }
            let picture_weak = picture_weak.clone();
            let backdrop_weak = backdrop_weak.clone();
            let dominant_ref = Rc::clone(&dominant_ref);
            ui_ref
                .core
                .artwork
                .request(title, artist, 232, move |texture, color| {
                    if let (Some(picture), Some(texture)) = (picture_weak.upgrade(), texture) {
                        picture.set_paintable(Some(texture));
                    }
                    if let Some(color) = color {
                        *dominant_ref.borrow_mut() = Some(color);
                        if let Some(backdrop) = backdrop_weak.upgrade() {
                            backdrop.queue_draw();
                        }
                    }
                });
        });
    }

    if let Some(badge_text) = album_quality_summary(album) {
        let badge = gtk::Label::new(Some(&badge_text));
        badge.add_css_class("quality-badge");
        badge.set_halign(gtk::Align::Start);
        badge.set_margin_top(4);
        meta.append(&badge);
    }

    let buttons = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(10)
        .margin_top(12)
        .build();
    let play = gtk::Button::builder().label("Play").build();
    play.add_css_class("pill");
    play.add_css_class("suggested-action");
    play.set_action_name(Some("win.play-album"));
    play.set_action_target_value(Some(&album.key().to_variant()));
    let shuffle = gtk::Button::builder().label("Shuffle").build();
    shuffle.add_css_class("pill");
    shuffle.set_action_name(Some("win.shuffle-album"));
    shuffle.set_action_target_value(Some(&album.key().to_variant()));
    buttons.append(&play);
    buttons.append(&shuffle);
    meta.append(&buttons);
    header.append(&meta);

    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .build();
    list.add_css_class("boxed-list");
    for track in &album.tracks {
        let row_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(12)
            .margin_top(10)
            .margin_bottom(10)
            .margin_start(12)
            .margin_end(12)
            .build();
        let number = gtk::Label::builder()
            .label(if track.track_number > 0 {
                track.track_number.to_string()
            } else {
                "·".to_string()
            })
            .width_chars(3)
            .xalign(1.0)
            .build();
        number.add_css_class("track-number");
        row_box.append(&number);
        let track_title = gtk::Label::builder()
            .label(&track.title)
            .xalign(0.0)
            .hexpand(true)
            .ellipsize(pango::EllipsizeMode::End)
            .tooltip_text(&track.title)
            .build();
        row_box.append(&track_title);
        let heart = gtk::Image::from_icon_name("emote-love-symbolic");
        heart.add_css_class("loved-heart");
        heart.set_visible(track.loved);
        row_box.append(&heart);
        if let Some(badge_text) = track.quality_badge() {
            let badge = gtk::Label::new(Some(&badge_text));
            badge.add_css_class("quality-badge");
            row_box.append(&badge);
        }
        let duration = gtk::Label::new(Some(&format_time(track.duration)));
        duration.add_css_class("duration-label");
        row_box.append(&duration);

        let row = gtk::ListBoxRow::builder().child(&row_box).build();
        context::attach_track_context_menu(&row, &ui.core, track.rel_path.clone());
        {
            let rel = track.rel_path.clone();
            ui.core.hub.subscribe_widget(&heart, move |heart, event| {
                if let AppEvent::LovedChanged { rel_path, loved } = event {
                    if rel_path == &rel {
                        heart.set_visible(*loved);
                    }
                }
            });
        }
        list.append(&row);
    }
    {
        let tracks = album.tracks.clone();
        let ui = Rc::clone(ui);
        list.connect_row_activated(move |_, row| {
            let index = row.index().max(0) as usize;
            ui.core.play_tracks(tracks.clone(), index);
        });
    }

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(24)
        .margin_top(32)
        .margin_bottom(32)
        .margin_start(32)
        .margin_end(32)
        .build();
    content.append(&header);
    content.append(&list);

    let clamp = adw::Clamp::builder()
        .maximum_size(920)
        .child(&content)
        .build();
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&clamp)
        .build();

    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&backdrop));
    overlay.add_overlay(&scroll);

    let page = adw::NavigationPage::builder()
        .title(album.title.clone())
        .child(&overlay)
        .build();
    ui.nav.push(&page);
}

/// Personal Last.fm play count for this album ("You've played this N times"),
/// fetched via album.getInfo with the username param when authenticated.
fn load_user_playcount(ui: &Rc<Ui>, album: &Album, label: &gtk::Label) {
    let Some(session) = ui.core.session.borrow().clone() else { return };
    let Some(client) = crate::lastfm::LastFmClient::new(Some(session.key.clone())) else {
        return;
    };
    let artist = album.artist.clone();
    let title = album.title.clone();
    let (tx, rx) = async_channel::bounded::<Option<i64>>(1);
    std::thread::Builder::new()
        .name("flaccy-album-plays".into())
        .spawn(move || {
            let count = client
                .fetch_album_user_playcount(&artist, &title, &session.username)
                .unwrap_or(None);
            let _ = tx.send_blocking(count);
        })
        .ok();
    let weak = label.downgrade();
    gtk::glib::spawn_future_local(async move {
        let Ok(Some(count)) = rx.recv().await else { return };
        if count <= 0 {
            return;
        }
        if let Some(label) = weak.upgrade() {
            label.set_label(&format!(
                "You've played this {count} time{} on Last.fm",
                if count == 1 { "" } else { "s" }
            ));
            label.set_visible(true);
        }
    });
}

fn album_quality_summary(album: &Album) -> Option<String> {
    let badges: Vec<String> = album.tracks.iter().filter_map(|t| t.quality_badge()).collect();
    if badges.is_empty() {
        return None;
    }
    let first = &badges[0];
    if badges.iter().all(|b| b == first) {
        Some(first.clone())
    } else {
        Some("Mixed Quality".to_string())
    }
}
