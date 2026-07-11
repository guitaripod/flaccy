use crate::events::AppEvent;
use crate::library::{Album, ArtistEntry};
use crate::ui::{albums, context, Ui};
use adw::prelude::*;
use gtk::glib::BoxedAnyObject;
use gtk::{gdk, gio, glib, pango};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

#[derive(Clone, Copy, PartialEq)]
enum ArtistSort {
    Name,
    MostPlayed,
    RecentlyPlayed,
    TrackCount,
}

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let store = gio::ListStore::new::<BoxedAnyObject>();
    let covers: Rc<RefCell<HashMap<String, (String, String)>>> =
        Rc::new(RefCell::new(HashMap::new()));
    let sort_mode = Rc::new(Cell::new(ArtistSort::Name));
    let bound: Rc<RefCell<HashMap<String, glib::WeakRef<adw::Avatar>>>> =
        Rc::new(RefCell::new(HashMap::new()));

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
            boxed
                .borrow::<ArtistEntry>()
                .name
                .to_lowercase()
                .contains(&query.to_lowercase())
        })
    };
    let filter_model = gtk::FilterListModel::new(Some(store.clone()), Some(filter.clone()));
    let selection = gtk::NoSelection::new(Some(filter_model));

    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(move |_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let cell = build_artist_cell();
        let gesture = gtk::GestureClick::builder().button(gdk::BUTTON_SECONDARY).build();
        let item_weak = item.downgrade();
        let anchor = cell.clone();
        gesture.connect_pressed(move |_, _, x, y| {
            let Some(item) = item_weak.upgrade() else { return };
            let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() else {
                return;
            };
            let name = boxed.borrow::<ArtistEntry>().name.clone();
            context::popup_menu_at(&anchor, &context::artist_menu(&name), x, y);
        });
        cell.add_controller(gesture);
        item.set_child(Some(&cell));
    });
    {
        let ui = Rc::clone(ui);
        let covers = Rc::clone(&covers);
        let bound = Rc::clone(&bound);
        factory.connect_bind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let Some(cell) = item.child() else { return };
            let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() else {
                return;
            };
            let artist = boxed.borrow::<ArtistEntry>();
            let Some(avatar) = cell.first_child().and_downcast::<adw::Avatar>() else {
                return;
            };
            let Some(name_label) = avatar.next_sibling().and_downcast::<gtk::Label>() else {
                return;
            };
            let Some(counts) = name_label.next_sibling().and_downcast::<gtk::Label>() else {
                return;
            };
            avatar.set_custom_image(gdk::Paintable::NONE);
            avatar.set_text(Some(&artist.name));
            name_label.set_label(&artist.name);
            name_label.set_tooltip_text(Some(&artist.name));
            counts.set_label(&format!(
                "{} album{} · {} track{}",
                artist.album_count,
                if artist.album_count == 1 { "" } else { "s" },
                artist.track_count,
                if artist.track_count == 1 { "" } else { "s" }
            ));
            let key = crate::hygiene::artist_key(&artist.name);
            if let Some((title, album_artist)) = covers.borrow().get(&key).cloned() {
                let expected = key.clone();
                let item_weak = item.downgrade();
                let weak = avatar.downgrade();
                ui.core.artwork.request(&title, &album_artist, 120, move |texture, _| {
                    if let (Some(avatar), Some(texture)) = (weak.upgrade(), texture) {
                        if still_bound_artist(&item_weak, &expected) {
                            avatar.set_custom_image(Some(texture));
                        }
                    }
                });
            }
            bound.borrow_mut().insert(key, avatar.downgrade());
        });
    }
    {
        let bound = Rc::clone(&bound);
        factory.connect_unbind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            if let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() {
                let key = crate::hygiene::artist_key(&boxed.borrow::<ArtistEntry>().name);
                bound.borrow_mut().remove(&key);
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
            let name = boxed.borrow::<ArtistEntry>().name.clone();
            push_artist_page(&ui, &name);
        });
    }

    let empty = adw::StatusPage::builder()
        .icon_name("system-users-symbolic")
        .title("No Artists")
        .description("Artists appear here once your library has music.")
        .build();

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(&grid)
        .build();

    let sort_dropdown =
        gtk::DropDown::from_strings(&["Name", "Most Played", "Recently Played", "Track Count"]);
    sort_dropdown.set_valign(gtk::Align::Center);
    sort_dropdown.set_tooltip_text(Some("Sort artists"));
    let sort_label = gtk::Label::new(Some("Sort"));
    sort_label.add_css_class("dim");
    sort_label.add_css_class("caption");
    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .margin_top(18)
        .margin_start(24)
        .margin_end(24)
        .halign(gtk::Align::End)
        .build();
    header.append(&sort_label);
    header.append(&sort_dropdown);

    let grid_box = gtk::Box::new(gtk::Orientation::Vertical, 0);
    grid_box.append(&header);
    grid_box.append(&scroll);

    let stack = gtk::Stack::new();
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&grid_box, Some("grid"));

    let repopulate: Rc<dyn Fn()> = {
        let store = store.clone();
        let covers = Rc::clone(&covers);
        let sort_mode = Rc::clone(&sort_mode);
        let ui = Rc::clone(ui);
        Rc::new(move || {
            let library = ui.core.library.borrow().clone();
            *covers.borrow_mut() = representative_covers(&library.albums);
            let mut sorted = library.artists.clone();
            sort_artists(&mut sorted, sort_mode.get());
            let items: Vec<BoxedAnyObject> =
                sorted.into_iter().map(BoxedAnyObject::new).collect();
            store.splice(0, store.n_items(), &items);
        })
    };

    let rebuild = {
        let stack = stack.clone();
        let ui = Rc::clone(ui);
        let repopulate = Rc::clone(&repopulate);
        let applied = Cell::new(0u64);
        move || {
            let library = ui.core.library.borrow().clone();
            let fingerprint = artists_fingerprint(&library.artists);
            if applied.replace(fingerprint) != fingerprint {
                repopulate();
            }
            stack.set_visible_child_name(if library.artists.is_empty() {
                "empty"
            } else {
                "grid"
            });
        }
    };
    rebuild();

    {
        let sort_mode = Rc::clone(&sort_mode);
        let repopulate = Rc::clone(&repopulate);
        sort_dropdown.connect_selected_notify(move |dropdown| {
            let mode = match dropdown.selected() {
                1 => ArtistSort::MostPlayed,
                2 => ArtistSort::RecentlyPlayed,
                3 => ArtistSort::TrackCount,
                _ => ArtistSort::Name,
            };
            if sort_mode.replace(mode) != mode {
                repopulate();
            }
        });
    }

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
        let covers = Rc::clone(&covers);
        let bound = Rc::clone(&bound);
        ui.core.hub.clone().subscribe_widget(&stack, move |_, event| {
            if let AppEvent::AlbumEnriched { title, artist } = event {
                let key = crate::hygiene::artist_key(artist);
                let is_rep =
                    matches!(covers.borrow().get(&key), Some((t, a)) if t == title && a == artist);
                if !is_rep {
                    return;
                }
                ui.core.artwork.invalidate(title, artist);
                if let Some(avatar) = bound.borrow().get(&key).and_then(|w| w.upgrade()) {
                    let weak = avatar.downgrade();
                    let bound = Rc::clone(&bound);
                    ui.core.artwork.request(title, artist, 120, move |texture, _| {
                        if let (Some(avatar), Some(texture)) = (weak.upgrade(), texture) {
                            let still = bound
                                .borrow()
                                .get(&key)
                                .and_then(|w| w.upgrade())
                                .is_some_and(|current| current == avatar);
                            if still {
                                avatar.set_custom_image(Some(texture));
                            }
                        }
                    });
                }
            }
        });
    }

    stack.upcast()
}

/// Picks each artist's cover-source album — the one with the most tracks, so a
/// stray single doesn't win over the artist's main record — keyed by artist
/// name to the album's `(title, artist)` artwork-cache lookup pair.
fn representative_covers(albums: &[Album]) -> HashMap<String, (String, String)> {
    let mut best: HashMap<String, &Album> = HashMap::new();
    for album in albums {
        best.entry(crate::hygiene::artist_key(&album.artist))
            .and_modify(|current| {
                if album.tracks.len() > current.tracks.len() {
                    *current = album;
                }
            })
            .or_insert(album);
    }
    best.into_iter()
        .map(|(artist, album)| (artist, (album.title.clone(), album.artist.clone())))
        .collect()
}

fn sort_artists(artists: &mut [ArtistEntry], mode: ArtistSort) {
    let by_name = |a: &ArtistEntry, b: &ArtistEntry| a.name.to_lowercase().cmp(&b.name.to_lowercase());
    match mode {
        ArtistSort::Name => artists.sort_by(by_name),
        ArtistSort::MostPlayed => {
            artists.sort_by(|a, b| b.play_count.cmp(&a.play_count).then_with(|| by_name(a, b)))
        }
        ArtistSort::RecentlyPlayed => {
            artists.sort_by(|a, b| b.last_played.cmp(&a.last_played).then_with(|| by_name(a, b)))
        }
        ArtistSort::TrackCount => {
            artists.sort_by(|a, b| b.track_count.cmp(&a.track_count).then_with(|| by_name(a, b)))
        }
    }
}

/// Guards an async avatar callback against GridView cell recycling: only paint
/// if the shared card is still bound to the artist whose cover was requested.
fn still_bound_artist(item: &glib::WeakRef<gtk::ListItem>, expected: &str) -> bool {
    item.upgrade()
        .and_then(|item| item.item())
        .and_downcast::<BoxedAnyObject>()
        .is_some_and(|boxed| crate::hygiene::artist_key(&boxed.borrow::<ArtistEntry>().name) == expected)
}

/// Empty artist-card shell reused by the GridView factory: an `adw::Avatar`
/// (initials fallback), name, and counts in fixed order. The bind step fills
/// them and overpaints the avatar with the representative album's cover.
fn build_artist_cell() -> gtk::Box {
    let cell = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .width_request(168)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Start)
        .build();
    cell.add_css_class("album-tile");

    let avatar = adw::Avatar::new(120, None, true);
    avatar.set_halign(gtk::Align::Center);
    cell.append(&avatar);

    let name = gtk::Label::builder()
        .halign(gtk::Align::Center)
        .justify(gtk::Justification::Center)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(18)
        .build();
    name.add_css_class("album-title");
    cell.append(&name);

    let counts = gtk::Label::builder().halign(gtk::Align::Center).build();
    counts.add_css_class("dim");
    counts.add_css_class("caption");
    cell.append(&counts);

    cell
}

pub fn push_artist_page(ui: &Rc<Ui>, artist: &str) {
    let library = ui.core.library.borrow().clone();
    let albums: Vec<Album> = library
        .albums
        .iter()
        .filter(|album| crate::hygiene::artist_key(&album.artist) == crate::hygiene::artist_key(artist))
        .cloned()
        .collect();

    let flow = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .homogeneous(true)
        .column_spacing(18)
        .row_spacing(24)
        .margin_top(24)
        .margin_bottom(24)
        .margin_start(24)
        .margin_end(24)
        .min_children_per_line(2)
        .max_children_per_line(10)
        .valign(gtk::Align::Start)
        .activate_on_single_click(true)
        .build();
    for album in &albums {
        flow.append(&album_cell_for_artist(ui, album));
    }
    {
        let ui = Rc::clone(ui);
        let albums = albums.clone();
        flow.connect_child_activated(move |_, child| {
            if let Some(album) = albums.get(child.index().max(0) as usize) {
                albums::push_album_detail(&ui, album);
            }
        });
    }

    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(18)
        .margin_top(24)
        .margin_start(24)
        .margin_end(24)
        .build();
    let avatar = adw::Avatar::new(72, Some(artist), true);
    header.append(&avatar);
    let title_box = gtk::Box::new(gtk::Orientation::Vertical, 6);
    title_box.set_valign(gtk::Align::Center);
    let title = gtk::Label::builder().label(artist).xalign(0.0).build();
    title.add_css_class("title-1");
    title_box.append(&title);
    let station = gtk::Button::builder().label("Start Station").build();
    station.add_css_class("pill");
    station.add_css_class("suggested-action");
    station.set_halign(gtk::Align::Start);
    station.set_action_name(Some("win.artist-station"));
    station.set_action_target_value(Some(&artist.to_variant()));
    title_box.append(&station);
    header.append(&title_box);

    let chips = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(6)
        .margin_top(10)
        .margin_start(24)
        .margin_end(24)
        .build();

    let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
    content.append(&header);
    content.append(&chips);
    if let Some(bio) = ui.core.db.artist_bio(artist).filter(|b| !b.is_empty()) {
        let bio_label = gtk::Label::builder()
            .label(&bio)
            .xalign(0.0)
            .wrap(true)
            .margin_top(14)
            .margin_start(24)
            .margin_end(24)
            .build();
        bio_label.add_css_class("dim");
        content.append(&bio_label);
    }
    content.append(&flow);
    let similar_box = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .margin_start(24)
        .margin_end(24)
        .margin_bottom(24)
        .build();
    content.append(&similar_box);

    load_artist_extras(ui, artist, &avatar, &chips, &similar_box);

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&content)
        .build();

    let page = adw::NavigationPage::builder()
        .title(artist)
        .child(&scroll)
        .build();
    ui.nav.push(&page);
}

/// Last.fm's generic star placeholder, rejected by URL content hash exactly as
/// the iOS ArtistImageService does.
const LASTFM_PLACEHOLDER_HASH: &str = "2a96cbd8b46e442fc41c2b86b821562f";

struct ArtistExtras {
    image: Option<(u32, u32, Vec<u8>)>,
    tags: Vec<String>,
    similar: Vec<String>,
}

/// Fetches the artist photo (disk-cached), Last.fm genre chips (first 6 top
/// tags) and the similar-artists-in-library row on a worker thread, then
/// fills the header widgets.
fn load_artist_extras(
    ui: &Rc<Ui>,
    artist: &str,
    avatar: &adw::Avatar,
    chips: &gtk::Box,
    similar_box: &gtk::Box,
) {
    let artist = artist.to_string();
    let db_path = ui.core.db_path.clone();
    let session_key = ui.core.session.borrow().as_ref().map(|s| s.key.clone());
    let library_artists: Vec<String> = ui
        .core
        .library
        .borrow()
        .artists
        .iter()
        .map(|a| a.name.clone())
        .collect();
    let (tx, rx) = async_channel::bounded::<ArtistExtras>(1);
    let artist_for_thread = artist.clone();
    std::thread::Builder::new()
        .name("flaccy-artist-page".into())
        .spawn(move || {
            let Ok(db) = crate::db::Db::open(&db_path) else { return };
            let client = crate::lastfm::LastFmClient::new(session_key);
            let image = db
                .artist_image_url(&artist_for_thread)
                .filter(|url| !url.contains(LASTFM_PLACEHOLDER_HASH))
                .and_then(|url| load_artist_image(&artist_for_thread, &url));
            let tags = client
                .as_ref()
                .and_then(|c| c.fetch_top_tags(&artist_for_thread, 6).ok())
                .unwrap_or_default();
            let similar = crate::enrichment::similar_in_library_blocking(
                &db,
                client.as_ref(),
                &artist_for_thread,
                &library_artists,
            )
            .into_iter()
            .filter(|(name, _)| !name.eq_ignore_ascii_case(&artist_for_thread))
            .map(|(name, _)| name)
            .take(8)
            .collect();
            let _ = tx.send_blocking(ArtistExtras { image, tags, similar });
        })
        .ok();

    let ui = Rc::clone(ui);
    let avatar = avatar.downgrade();
    let chips = chips.downgrade();
    let similar_box = similar_box.downgrade();
    gtk::glib::spawn_future_local(async move {
        let Ok(extras) = rx.recv().await else { return };
        if let (Some(avatar), Some((width, height, rgba))) = (avatar.upgrade(), extras.image) {
            let texture = gtk::gdk::MemoryTexture::new(
                width as i32,
                height as i32,
                gtk::gdk::MemoryFormat::R8g8b8a8,
                &gtk::glib::Bytes::from_owned(rgba),
                (width * 4) as usize,
            );
            avatar.set_custom_image(Some(&texture));
        }
        if let Some(chips) = chips.upgrade() {
            let tags = if extras.tags.is_empty() {
                library_genre_fallback(&ui, &artist)
            } else {
                extras.tags.clone()
            };
            for tag in &tags {
                let chip = gtk::Label::new(Some(tag));
                chip.add_css_class("genre-chip");
                chips.append(&chip);
            }
        }
        if let Some(similar_box) = similar_box.upgrade() {
            if !extras.similar.is_empty() {
                let heading = gtk::Label::builder()
                    .label("SIMILAR ARTISTS IN YOUR LIBRARY")
                    .xalign(0.0)
                    .build();
                heading.add_css_class("stat-caption");
                similar_box.append(&heading);
                let row = gtk::Box::builder()
                    .orientation(gtk::Orientation::Horizontal)
                    .spacing(8)
                    .build();
                for name in &extras.similar {
                    let button = gtk::Button::with_label(name);
                    button.add_css_class("pill");
                    button.add_css_class("chip");
                    let ui = Rc::clone(&ui);
                    let name = name.clone();
                    button.connect_clicked(move |_| push_artist_page(&ui, &name));
                    row.append(&button);
                }
                let scroll = gtk::ScrolledWindow::builder()
                    .vscrollbar_policy(gtk::PolicyType::Never)
                    .hscrollbar_policy(gtk::PolicyType::Automatic)
                    .min_content_height(52)
                    .child(&row)
                    .build();
                similar_box.append(&scroll);
            }
        }
    });
}

/// Offline fallback for the genre chips: the distinct genres of the artist's
/// library albums, used when Last.fm has no top tags for the artist.
fn library_genre_fallback(ui: &Rc<Ui>, artist: &str) -> Vec<String> {
    let library = ui.core.library.borrow().clone();
    let mut seen = std::collections::HashSet::new();
    library
        .albums
        .iter()
        .filter(|album| crate::hygiene::artist_key(&album.artist) == crate::hygiene::artist_key(artist))
        .filter_map(|album| album.genre.clone())
        .filter(|genre| !genre.is_empty() && seen.insert(genre.to_lowercase()))
        .take(6)
        .collect()
}

/// Downloads an artist photo (or reuses the XDG-cached copy) and decodes it to
/// a 160px RGBA thumbnail for the avatar.
fn load_artist_image(artist: &str, url: &str) -> Option<(u32, u32, Vec<u8>)> {
    let cache_dir = dirs::cache_dir()?.join("flaccy").join("artists");
    let _ = std::fs::create_dir_all(&cache_dir);
    let cache_path = cache_dir.join(format!("{:016x}", crate::palette::fnv1a_64(artist)));
    let data = if let Ok(data) = std::fs::read(&cache_path) {
        data
    } else {
        let response = ureq::AgentBuilder::new()
            .timeout(std::time::Duration::from_secs(15))
            .build()
            .get(url)
            .call()
            .ok()?;
        let mut data = Vec::new();
        use std::io::Read;
        response
            .into_reader()
            .take(10 * 1024 * 1024)
            .read_to_end(&mut data)
            .ok()?;
        if data.is_empty() {
            return None;
        }
        let _ = std::fs::write(&cache_path, &data);
        data
    };
    let decoded = image::load_from_memory(&data).ok()?;
    let thumbnail = decoded.thumbnail(160, 160).to_rgba8();
    let (width, height) = thumbnail.dimensions();
    Some((width, height, thumbnail.into_raw()))
}

fn album_cell_for_artist(ui: &Rc<Ui>, album: &Album) -> gtk::FlowBoxChild {
    let cell = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .width_request(168)
        .build();
    let picture = gtk::Picture::builder()
        .width_request(168)
        .height_request(168)
        .content_fit(gtk::ContentFit::Cover)
        .build();
    picture.set_overflow(gtk::Overflow::Hidden);
    picture.add_css_class("cover");
    picture.set_paintable(Some(&ui.core.artwork.placeholder(&album.key())));
    {
        let weak = picture.downgrade();
        ui.core
            .artwork
            .request(&album.title, &album.artist, 168, move |texture, _| {
                if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                    picture.set_paintable(Some(texture));
                }
            });
    }
    cell.append(&picture);
    let title = gtk::Label::builder()
        .label(&album.title)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(18)
        .build();
    title.add_css_class("album-title");
    cell.append(&title);
    if let Some(year) = album.year.as_ref().filter(|y| !y.is_empty()) {
        let year_label = gtk::Label::builder().label(year).xalign(0.0).build();
        year_label.add_css_class("dim");
        year_label.add_css_class("caption");
        cell.append(&year_label);
    }
    let child = gtk::FlowBoxChild::builder().child(&cell).build();
    crate::ui::context::attach_album_context_menu(&child, album.key());
    child
}

/// Digest of the rendered artist rows, so enrichment-driven reloads (which
/// never change artist names or counts) skip rebuilding the list.
fn artists_fingerprint(artists: &[crate::library::ArtistEntry]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for artist in artists {
        let row = format!(
            "{}|{}|{}|{}|{:?}",
            artist.name,
            artist.album_count,
            artist.track_count,
            artist.play_count,
            artist.last_played
        );
        hash = hash.rotate_left(5) ^ crate::palette::fnv1a_64(&row);
    }
    hash
}
