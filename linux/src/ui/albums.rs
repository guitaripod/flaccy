use crate::events::AppEvent;
use crate::library::{format_time, Album, Track};
use crate::ui::{context, Ui};
use adw::prelude::*;
use gtk::glib::BoxedAnyObject;
use gtk::{gdk, gio, glib, pango};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

/// Mirrors LibraryViewModel.AlbumSort on the Apple clients — same options,
/// same semantics, same order.
#[derive(Clone, Copy, PartialEq)]
enum AlbumSort {
    Title,
    Artist,
    Year,
    RecentlyAdded,
    RecentlyPlayed,
}

impl AlbumSort {
    const ALL: [AlbumSort; 5] = [
        AlbumSort::Title,
        AlbumSort::Artist,
        AlbumSort::Year,
        AlbumSort::RecentlyAdded,
        AlbumSort::RecentlyPlayed,
    ];

    fn label(self) -> &'static str {
        match self {
            AlbumSort::Title => "Title",
            AlbumSort::Artist => "Artist",
            AlbumSort::Year => "Year",
            AlbumSort::RecentlyAdded => "Recently Added",
            AlbumSort::RecentlyPlayed => "Recently Played",
        }
    }

    fn id(self) -> &'static str {
        match self {
            AlbumSort::Title => "title",
            AlbumSort::Artist => "artist",
            AlbumSort::Year => "year",
            AlbumSort::RecentlyAdded => "recently_added",
            AlbumSort::RecentlyPlayed => "recently_played",
        }
    }

    fn from_id(id: &str) -> AlbumSort {
        Self::ALL
            .into_iter()
            .find(|sort| sort.id() == id)
            .unwrap_or(AlbumSort::Artist)
    }
}

/// Same comparisons as iOS sortedAlbums: title/artist alphabetical, year
/// ascending with unknown years last, recently added/played newest first with
/// never-played albums trailing alphabetically.
fn sort_albums(albums: &mut [Album], sort: AlbumSort) {
    let title_key = |album: &Album| album.title.to_lowercase();
    match sort {
        AlbumSort::Title => albums.sort_by_key(|a| (title_key(a), a.artist.to_lowercase())),
        AlbumSort::Artist => albums.sort_by_key(|a| (a.artist.to_lowercase(), title_key(a))),
        AlbumSort::Year => albums.sort_by_key(|a| {
            (
                a.year.clone().filter(|y| !y.is_empty()).unwrap_or_else(|| "9999".to_string()),
                title_key(a),
            )
        }),
        AlbumSort::RecentlyAdded => albums.sort_by_key(|a| (-a.added_unix(), title_key(a))),
        AlbumSort::RecentlyPlayed => albums.sort_by_key(|a| match a.last_played_unix() {
            Some(played) => (0, -played, title_key(a)),
            None => (1, 0, title_key(a)),
        }),
    }
}

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let store = gio::ListStore::new::<BoxedAnyObject>();
    let sort_mode = Rc::new(Cell::new(AlbumSort::from_id(
        &ui.core.config.borrow().album_sort,
    )));

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
        .min_columns(1)
        // Low starting max so natural width stays small; grows with allocation.
        .max_columns(3)
        .single_click_activate(true)
        .margin_top(24)
        .margin_bottom(24)
        .margin_start(24)
        .margin_end(24)
        .build();
    grid.add_css_class("album-grid");
    crate::ui::controls::bind_adaptive_grid_columns(&grid, 156);
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
    ui.register_scroller(&scroll);

    let sort_labels: Vec<&str> = AlbumSort::ALL.iter().map(|s| s.label()).collect();
    let sort_dropdown = gtk::DropDown::from_strings(&sort_labels);
    sort_dropdown.set_valign(gtk::Align::Center);
    sort_dropdown.set_tooltip_text(Some("Sort albums"));
    sort_dropdown.set_selected(
        AlbumSort::ALL
            .iter()
            .position(|s| *s == sort_mode.get())
            .unwrap_or(1) as u32,
    );
    let sort_label = gtk::Label::new(Some("Sort"));
    sort_label.add_css_class("dim");
    sort_label.add_css_class("caption");
    let sort_header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .margin_top(18)
        .margin_start(24)
        .margin_end(24)
        .halign(gtk::Align::End)
        .build();
    sort_header.append(&sort_label);
    sort_header.append(&sort_dropdown);

    let grid_content = gtk::Box::new(gtk::Orientation::Vertical, 0);
    grid_content.append(&sort_header);
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
    stack.set_hhomogeneous(false);
    stack.set_vhomogeneous(false);
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&grid_content, Some("grid"));

    let rebuild: Rc<dyn Fn()> = {
        let store = store.clone();
        let stack = stack.clone();
        let scroll = scroll.clone();
        let ui = Rc::clone(ui);
        let sort_mode = Rc::clone(&sort_mode);
        let applied = Cell::new(0u64);
        Rc::new(move || {
            let library = ui.core.library.borrow().clone();
            let mut albums = library.albums.clone();
            sort_albums(&mut albums, sort_mode.get());
            let fingerprint = albums_fingerprint(&albums);
            if applied.replace(fingerprint) != fingerprint {
                let saved = scroll.vadjustment().value();
                let items: Vec<BoxedAnyObject> = albums
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
        })
    };
    rebuild();

    {
        let ui = Rc::clone(ui);
        let sort_mode = Rc::clone(&sort_mode);
        let rebuild = Rc::clone(&rebuild);
        let scroll = scroll.clone();
        sort_dropdown.connect_selected_notify(move |dropdown| {
            let sort = AlbumSort::ALL[(dropdown.selected() as usize).min(AlbumSort::ALL.len() - 1)];
            if sort_mode.replace(sort) == sort {
                return;
            }
            ui.core.config.borrow_mut().album_sort = sort.id().to_string();
            ui.core.save_config();
            scroll.vadjustment().set_value(0.0);
            rebuild();
        });
    }

    {
        let rebuild = Rc::clone(&rebuild);
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
        .width_request(140)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Start)
        .hexpand(true)
        .build();
    cell.add_css_class("album-tile");

    let picture = gtk::Picture::builder()
        .width_request(140)
        .height_request(140)
        .content_fit(gtk::ContentFit::Cover)
        .hexpand(true)
        .build();
    picture.set_overflow(gtk::Overflow::Hidden);
    picture.add_css_class("cover");
    cell.append(&picture);

    let title = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(16)
        .hexpand(true)
        .build();
    title.add_css_class("album-title");
    cell.append(&title);

    let subtitle = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(18)
        .hexpand(true)
        .build();
    subtitle.add_css_class("dim");
    subtitle.add_css_class("caption");
    cell.append(&subtitle);

    cell
}

/// A section header announcing a physical disc or vinyl side, e.g.
/// "Side A · 4 songs · 18 min", evoking the divider between records in a set.
fn disc_header(label: &str, count: usize, duration: f64) -> gtk::Box {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .margin_top(10)
        .margin_start(4)
        .margin_end(6)
        .build();
    row.add_css_class("disc-header");
    let icon = gtk::Image::from_icon_name("media-optical-symbolic");
    icon.add_css_class("disc-header-icon");
    row.append(&icon);
    let name = gtk::Label::builder().label(label).xalign(0.0).build();
    name.add_css_class("disc-header-label");
    row.append(&name);
    let songs = if count == 1 {
        "1 song".to_string()
    } else {
        format!("{count} songs")
    };
    let meta = gtk::Label::builder()
        .label(format!(
            "{songs} · {} min",
            (duration / 60.0).round().max(1.0) as i64
        ))
        .hexpand(true)
        .xalign(1.0)
        .build();
    meta.add_css_class("disc-header-meta");
    row.append(&meta);
    row
}

/// Builds one boxed track list for a slice of an album's tracks. `base` is the
/// slice's offset within `all_tracks` so activating a row queues the whole
/// album from the correct position regardless of which disc section it sits in.
fn build_track_list(
    ui: &Rc<Ui>,
    all_tracks: &Rc<Vec<Track>>,
    base: usize,
    tracks: &[Track],
) -> gtk::ListBox {
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .build();
    list.add_css_class("boxed-list");
    for track in tracks {
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
        let all_tracks = Rc::clone(all_tracks);
        let ui = Rc::clone(ui);
        list.connect_row_activated(move |_, row| {
            let index = base + row.index().max(0) as usize;
            ui.core.play_tracks((*all_tracks).clone(), index);
        });
    }
    list
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
    header.add_css_class("album-detail-header");

    let picture = gtk::Picture::builder()
        .width_request(160)
        .height_request(160)
        .content_fit(gtk::ContentFit::Cover)
        .valign(gtk::Align::Start)
        .halign(gtk::Align::Start)
        .build();
    picture.set_overflow(gtk::Overflow::Hidden);
    picture.add_css_class("cover-large");
    picture.add_css_class("album-detail-cover");
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
        .hexpand(true)
        .build();
    let title = gtk::Label::builder()
        .label(&album.title)
        .xalign(0.0)
        .wrap(true)
        .wrap_mode(pango::WrapMode::WordChar)
        .build();
    title.add_css_class("title-1");
    meta.append(&title);
    let artist = gtk::Label::builder().label(&album.artist).xalign(0.0).build();
    artist.add_css_class("title-4");
    artist.add_css_class("dim");
    artist.set_halign(gtk::Align::Start);
    {
        let album_artist = album.artist.clone();
        crate::ui::controls::attach_label_nav(ui, &artist, "Go to Artist", move |ui| {
            crate::ui::goto_artist(ui, &album_artist);
        });
    }
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

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(24)
        .margin_top(32)
        .margin_bottom(32)
        .margin_start(32)
        .margin_end(32)
        .build();
    content.add_css_class("album-detail-content");
    content.append(&header);

    let all_tracks = Rc::new(album.tracks.clone());
    match crate::library::disc_sections(&album.tracks) {
        Some(sections) => {
            let mut base = 0usize;
            for section in &sections {
                content.append(&disc_header(
                    &section.label,
                    section.tracks.len(),
                    section.duration(),
                ));
                content.append(&build_track_list(ui, &all_tracks, base, &section.tracks));
                base += section.tracks.len();
            }
        }
        None => content.append(&build_track_list(ui, &all_tracks, 0, &album.tracks)),
    }

    let detail_bin = adw::BreakpointBin::new();
    detail_bin.set_child(Some(&content));
    install_album_detail_breakpoints(&detail_bin, &header, &picture, &content);

    let clamp = adw::Clamp::builder()
        .maximum_size(920)
        .child(&detail_bin)
        .build();
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&clamp)
        .build();
    ui.register_scroller(&scroll);

    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&backdrop));
    overlay.add_overlay(&scroll);

    let page = adw::NavigationPage::builder()
        .title(album.title.clone())
        .child(&overlay)
        .build();
    ui.nav.push(&page);
}

/// Stack the album hero vertically and shrink the cover once the detail page
/// no longer has room for the side-by-side desktop layout.
fn install_album_detail_breakpoints(
    bin: &adw::BreakpointBin,
    header: &gtk::Box,
    picture: &gtk::Picture,
    content: &gtk::Box,
) {
    let compact = adw::Breakpoint::new(adw::BreakpointCondition::new_length(
        adw::BreakpointConditionLengthType::MaxWidth,
        560.0,
        adw::LengthUnit::Px,
    ));
    {
        let header = header.clone();
        let picture = picture.clone();
        let content = content.clone();
        compact.connect_apply(move |_| {
            header.set_orientation(gtk::Orientation::Vertical);
            header.set_spacing(16);
            picture.set_size_request(148, 148);
            picture.set_halign(gtk::Align::Center);
            content.set_margin_start(16);
            content.set_margin_end(16);
            content.set_margin_top(20);
            content.set_margin_bottom(20);
            content.set_spacing(16);
        });
    }
    {
        let header = header.clone();
        let picture = picture.clone();
        let content = content.clone();
        compact.connect_unapply(move |_| {
            header.set_orientation(gtk::Orientation::Horizontal);
            header.set_spacing(24);
            picture.set_size_request(200, 200);
            picture.set_halign(gtk::Align::Start);
            content.set_margin_start(32);
            content.set_margin_end(32);
            content.set_margin_top(32);
            content.set_margin_bottom(32);
            content.set_spacing(24);
        });
    }
    bin.add_breakpoint(compact);
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

#[cfg(test)]
mod sort_tests {
    use super::*;
    use crate::library::TrackRow;

    fn album(title: &str, year: Option<&str>, added: i64, played: Option<i64>) -> Album {
        Album {
            title: title.to_string(),
            artist: "Artist".to_string(),
            year: year.map(String::from),
            genre: None,
            tracks: vec![TrackRow {
                id: 0,
                rel_path: format!("{title}/01.flac"),
                title: "Song".to_string(),
                artist: "Artist".to_string(),
                album: title.to_string(),
                track_number: 1,
                duration: 100.0,
                codec: None,
                bit_depth: None,
                sample_rate: None,
                channels: None,
                loved: false,
                play_count: 0,
                date_added: added,
                last_played: played,
            }],
        }
    }

    fn titles(albums: &[Album]) -> Vec<&str> {
        albums.iter().map(|a| a.title.as_str()).collect()
    }

    #[test]
    fn recently_added_orders_newest_first() {
        let mut albums = vec![
            album("Old", None, 100, None),
            album("New", None, 300, None),
            album("Mid", None, 200, None),
        ];
        sort_albums(&mut albums, AlbumSort::RecentlyAdded);
        assert_eq!(titles(&albums), vec!["New", "Mid", "Old"]);
    }

    #[test]
    fn year_sorts_ascending_with_unknown_last() {
        let mut albums = vec![
            album("NoYear", None, 0, None),
            album("Nineties", Some("1994"), 0, None),
            album("Modern", Some("2020"), 0, None),
        ];
        sort_albums(&mut albums, AlbumSort::Year);
        assert_eq!(titles(&albums), vec!["Nineties", "Modern", "NoYear"]);
    }

    #[test]
    fn recently_played_puts_never_played_last_alphabetically() {
        let mut albums = vec![
            album("Zebra Unplayed", None, 0, None),
            album("Alpha Unplayed", None, 0, None),
            album("Played Older", None, 0, Some(50)),
            album("Played Newer", None, 0, Some(90)),
        ];
        sort_albums(&mut albums, AlbumSort::RecentlyPlayed);
        assert_eq!(
            titles(&albums),
            vec!["Played Newer", "Played Older", "Alpha Unplayed", "Zebra Unplayed"]
        );
    }

    #[test]
    fn sort_ids_round_trip() {
        for sort in AlbumSort::ALL {
            assert!(AlbumSort::from_id(sort.id()) == sort);
        }
        assert!(AlbumSort::from_id("garbage") == AlbumSort::Artist);
    }
}
