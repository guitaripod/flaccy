//! The artist page. A full-bleed photo hero with the name set large; Play,
//! Shuffle and Station; the top songs (the world's and the person's) beside
//! the latest and the most played record; the person's own history with the
//! artist; the discography by kind; the records they appear on; similar
//! artists the library holds; and the biography. Everything local renders at
//! once; the history, the photo and what Last.fm knows fill in as they land.
//! A bar in the artist's colour with the name and a play button slides in
//! once the hero has scrolled away.

mod discography;
mod hero;
pub mod listening;
mod people;
mod songs;

use crate::events::AppEvent;
use crate::library::{format_total_duration, Library, Track};
use crate::ui::{context, Ui};
use adw::prelude::*;
use flaccy_library::artist_listening::ArtistListening;
use flaccy_shared::load_progress::group_digits;
use gtk::{gdk, gio, glib, pango};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

/// Last.fm's generic star placeholder, rejected by URL content hash exactly as
/// the iOS ArtistImageService does.
const LASTFM_PLACEHOLDER_HASH: &str = "2a96cbd8b46e442fc41c2b86b821562f";
const BODY_MAX_WIDTH: i32 = 1480;
const BODY_INSET: i32 = 40;
const PHOTO_MAX_SIDE: u32 = 1600;
const PORTRAIT_SIDE: u32 = 272;
/// The sleeve the hero shows without a photo, in points.
const SLEEVE_SIDE: u32 = 360;
const SIMILAR_LIMIT: usize = 12;
const POPULAR_FETCH: u32 = 40;
const TAG_LIMIT: usize = 6;
/// How long the songs wait for Last.fm's popular list before showing what the
/// library and the history know.
const POPULAR_PATIENCE: std::time::Duration = std::time::Duration::from_millis(2500);
/// Below this width the featured records move under the songs.
const SIDE_COLUMN_WIDTH: i32 = 1060;
const FEATURE_COLUMN: i32 = 400;
const STICKY_HEIGHT: i32 = 64;
/// How many points before the hero's bottom the bar starts to show, and over
/// how many it fades in.
const STICKY_LEAD: f64 = 150.0;
const STICKY_FADE: f64 = 70.0;

/// An artist's albums, split into the ones credited to them and the ones they
/// merely play on.
///
/// A composer on a Various Artists soundtrack is credited with no album at all,
/// so a page built from credits alone would be an empty page above a library
/// holding thirty-one of their tracks.
///
/// Returns positions in `library.albums` rather than copies of the albums.
pub fn artist_albums(library: &Library, artist: &str) -> (Vec<usize>, Vec<usize>) {
    let key = crate::hygiene::artist_key(artist);
    let mut credited = Vec::new();
    let mut appears_on = Vec::new();
    for (index, album) in library.albums.iter().enumerate() {
        if crate::hygiene::artist_key(&album.artist) == key {
            credited.push(index);
        } else if album
            .tracks
            .iter()
            .any(|track| crate::hygiene::artist_key(&track.artist) == key)
        {
            appears_on.push(index);
        }
    }
    (credited, appears_on)
}

/// A decoded picture and the colour it is mostly made of.
struct Photo {
    width: u32,
    height: u32,
    rgba: Vec<u8>,
    dominant: (u8, u8, u8),
}

impl Photo {
    fn texture(&self) -> gdk::Texture {
        gdk::MemoryTexture::new(
            self.width as i32,
            self.height as i32,
            gdk::MemoryFormat::R8g8b8a8,
            &glib::Bytes::from(&self.rgba),
            (self.width * 4) as usize,
        )
        .upcast()
    }
}

/// What the worker thread hands the page, in the order it learns it.
enum Arrival {
    Listening(ArtistListening),
    Photo(Photo),
    Bio(Option<String>),
    Popular(Vec<String>),
    Facts {
        tags: Vec<String>,
        similar: Vec<String>,
        reach: Option<(u64, u64)>,
    },
    Portrait(String, Photo),
}

struct Page {
    ui: Rc<Ui>,
    artist: String,
    owned: Vec<Track>,
    hero: hero::Hero,
    meta: String,
    songs: Rc<songs::SongsSection>,
    listening_slot: gtk::Box,
    similar_slot: gtk::Box,
    similar: RefCell<Option<people::SimilarRow>>,
    about: Rc<people::About>,
    dominant: Rc<RefCell<Option<(u8, u8, u8)>>>,
    has_photo_colour: Cell<bool>,
    backdrop: gtk::DrawingArea,
    sticky: gtk::Overlay,
    sticky_tint: gtk::DrawingArea,
    scroll: gtk::ScrolledWindow,
}

pub fn push_artist_page(ui: &Rc<Ui>, artist: &str) {
    let library = ui.core.library.borrow().clone();
    let (credited, appears_on) = artist_albums(&library, artist);
    let owned = ui.core.artist_tracks(artist);
    let meta = facts_line(&library, &credited, &appears_on, &owned);

    let hero = hero::Hero::new(artist, &meta);
    let dominant: Rc<RefCell<Option<(u8, u8, u8)>>> = Rc::new(RefCell::new(None));
    let backdrop = crate::ui::controls::hero_backdrop(&dominant);

    let body = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(44)
        .margin_top(22)
        .margin_bottom(48)
        .margin_start(BODY_INSET)
        .margin_end(BODY_INSET)
        .build();
    body.append(&action_row(artist, !owned.is_empty()));

    let songs = songs::SongsSection::new(ui);
    songs.set_fallback(owned.iter().take(songs::EXPANDED).cloned().collect());
    {
        let songs = Rc::downgrade(&songs);
        glib::timeout_add_local_once(POPULAR_PATIENCE, move || {
            if let Some(songs) = songs.upgrade() {
                songs.stop_waiting();
            }
        });
    }
    let (latest, favourite) = discography::featured(&library, &credited);
    body.append(&top_band(ui, &library, &songs, latest, favourite));

    let listening_slot = gtk::Box::new(gtk::Orientation::Vertical, 0);
    body.append(&listening_slot);
    if let Some(section) = discography::discography(ui, &library, &credited) {
        body.append(&section);
    }
    if let Some(section) = discography::appears_on(ui, &library, &appears_on) {
        body.append(&section);
    }
    let similar_slot = gtk::Box::new(gtk::Orientation::Vertical, 0);
    body.append(&similar_slot);
    let about = people::About::new(ui.core.db.artist_bio(artist).as_deref());
    body.append(&about.widget);

    let clamp = adw::Clamp::builder()
        .maximum_size(BODY_MAX_WIDTH + 2 * BODY_INSET)
        .tightening_threshold(BODY_MAX_WIDTH)
        .child(&body)
        .build();
    let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
    content.append(&hero.widget);
    content.append(&clamp);

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&content)
        .build();
    ui.register_scroller(&scroll);

    let (sticky, sticky_tint) = sticky_bar(artist, &dominant);
    let root = gtk::Overlay::new();
    root.set_child(Some(&backdrop));
    root.add_overlay(&scroll);
    root.add_overlay(&sticky);
    root.add_css_class("artist-page");

    let page = Rc::new(Page {
        ui: Rc::clone(ui),
        artist: artist.to_string(),
        owned,
        hero,
        meta,
        songs,
        listening_slot,
        similar_slot,
        similar: RefCell::new(None),
        about,
        dominant,
        has_photo_colour: Cell::new(false),
        backdrop,
        sticky,
        sticky_tint,
        scroll,
    });

    follow_scroll(&page);
    show_stand_in(&page, &library, &credited, &appears_on, favourite.or(latest));
    gather(&page, &library);
    refresh_when_enriched(&page);
    if ui.core.db.artist_bio(artist).is_none() || ui.core.db.artist_image_url(artist).is_none() {
        crate::enrichment::request_artist(&ui.core, artist);
    }

    let nav_page = adw::NavigationPage::builder()
        .title(artist)
        .child(&root)
        .build();
    unsafe {
        nav_page.set_data("artist-page", page);
    }
    ui.nav.push(&nav_page);
    crate::logger::info("ui", &format!("artist page opened: {artist}"));
}

/// "18 albums · 214 songs · 15 hr 20 min" ("releases" once singles or EPs
/// are among them), or the records they appear on for an artist credited
/// with none.
fn facts_line(library: &Library, credited: &[usize], appears_on: &[usize], owned: &[Track]) -> String {
    let mut parts = Vec::new();
    let all_albums = credited
        .iter()
        .all(|&index| discography::album_kind(&library.albums[index]) == discography::ReleaseKind::Album);
    match (credited.len(), appears_on.len()) {
        (0, 0) => {}
        (0, 1) => parts.push("Appears on 1 album".to_string()),
        (0, count) => parts.push(format!("Appears on {} albums", group_digits(count))),
        (1, _) if all_albums => parts.push("1 album".to_string()),
        (1, _) => parts.push("1 release".to_string()),
        (count, _) if all_albums => parts.push(format!("{} albums", group_digits(count))),
        (count, _) => parts.push(format!("{} releases", group_digits(count))),
    }
    if !owned.is_empty() {
        parts.push(discography::songs_text(owned.len()));
        let seconds: f64 = owned.iter().map(|track| track.duration).sum();
        parts.push(format_total_duration(seconds));
    }
    parts.join("  ·  ")
}

fn round_button(icon: &str, tooltip: &str, classes: &[&str]) -> gtk::Button {
    let button = gtk::Button::from_icon_name(icon);
    button.add_css_class("circular");
    for class in classes {
        button.add_css_class(class);
    }
    button.set_valign(gtk::Align::Center);
    button.set_tooltip_text(Some(tooltip));
    button.update_property(&[gtk::accessible::Property::Label(tooltip)]);
    button
}

fn action_row(artist: &str, playable: bool) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 14);
    row.add_css_class("artist-actions");
    let target = artist.to_variant();

    let play = round_button(
        "media-playback-start-symbolic",
        &format!("Play {artist}"),
        &["suggested-action", "artist-play"],
    );
    play.set_action_name(Some("win.artist-play"));
    play.set_action_target_value(Some(&target));
    play.set_sensitive(playable);
    row.append(&play);

    let shuffle = round_button("media-playlist-shuffle-symbolic", "Shuffle", &["artist-round"]);
    shuffle.set_action_name(Some("win.artist-shuffle"));
    shuffle.set_action_target_value(Some(&target));
    shuffle.set_sensitive(playable);
    row.append(&shuffle);

    let station_content = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    station_content.append(&gtk::Image::from_icon_name("flaccy-station-symbolic"));
    station_content.append(&gtk::Label::new(Some("Start Station")));
    let station = gtk::Button::builder().child(&station_content).build();
    station.add_css_class("pill");
    station.add_css_class("artist-station");
    station.set_valign(gtk::Align::Center);
    station.set_tooltip_text(Some("Play songs by this artist and the artists like them"));
    station.set_action_name(Some("win.artist-station"));
    station.set_action_target_value(Some(&target));
    row.append(&station);

    let more = round_button("view-more-symbolic", "More", &["artist-round"]);
    more.set_sensitive(playable);
    {
        let artist = artist.to_string();
        more.connect_clicked(move |button| {
            let menu = gio::Menu::new();
            for (label, action) in [
                ("Play Next", "win.artist-play-next"),
                ("Add to Queue", "win.artist-queue"),
            ] {
                let item = gio::MenuItem::new(Some(label), None);
                item.set_action_and_target_value(Some(action), Some(&artist.to_variant()));
                menu.append_item(&item);
            }
            let (x, y) = (button.width() as f64 / 2.0, button.height() as f64);
            context::popup_menu_at(button, &menu, x, y);
        });
    }
    row.append(&more);
    row
}

/// The songs, with the featured records beside them on a wide page and below
/// them on a narrow one.
fn top_band(
    ui: &Rc<Ui>,
    library: &Library,
    songs: &Rc<songs::SongsSection>,
    latest: Option<usize>,
    favourite: Option<usize>,
) -> gtk::Box {
    let band = gtk::Box::new(gtk::Orientation::Horizontal, 40);
    band.append(&songs.widget);
    let features = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(14)
        .width_request(FEATURE_COLUMN)
        .hexpand(false)
        .valign(gtk::Align::Start)
        .build();
    if let Some(index) = latest {
        let album = &library.albums[index];
        features.append(&discography::feature_card(
            ui,
            album,
            "LATEST RELEASE",
            &discography::latest_detail(album),
        ));
    }
    if let Some(index) = favourite {
        let album = &library.albums[index];
        features.append(&discography::feature_card(
            ui,
            album,
            "YOUR MOST PLAYED",
            &discography::favourite_detail(album),
        ));
    }
    if features.first_child().is_none() {
        return band;
    }
    features.set_margin_top(52);
    band.append(&features);
    {
        let features = features.downgrade();
        let band_weak = band.downgrade();
        crate::ui::resize::watch_width(&band, move |width, _| {
            let (Some(band), Some(features)) = (band_weak.upgrade(), features.upgrade()) else {
                return;
            };
            let wide = width >= SIDE_COLUMN_WIDTH;
            let orientation = if wide {
                gtk::Orientation::Horizontal
            } else {
                gtk::Orientation::Vertical
            };
            if band.orientation() != orientation {
                band.set_orientation(orientation);
                band.set_spacing(if wide { 40 } else { 24 });
                features.set_width_request(if wide { FEATURE_COLUMN } else { -1 });
                features.set_margin_top(if wide { 52 } else { 0 });
            }
        });
    }
    band
}

/// The bar that takes over from the hero once it scrolls away: the artist's
/// colour, a play button and the name.
fn sticky_bar(
    artist: &str,
    dominant: &Rc<RefCell<Option<(u8, u8, u8)>>>,
) -> (gtk::Overlay, gtk::DrawingArea) {
    let tint = gtk::DrawingArea::new();
    {
        let dominant = Rc::clone(dominant);
        tint.set_draw_func(move |_, cr, width, height| {
            let (r, g, b) = dominant.borrow().unwrap_or((52, 52, 58));
            let shade = |channel: u8| channel as f64 / 255.0 * 0.42 + 0.03;
            cr.set_source_rgb(shade(r), shade(g), shade(b));
            cr.rectangle(0.0, 0.0, width as f64, height as f64);
            let _ = cr.fill();
            cr.set_source_rgba(0.0, 0.0, 0.0, 0.25);
            cr.rectangle(0.0, height as f64 - 1.0, width as f64, 1.0);
            let _ = cr.fill();
        });
    }
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(14)
        .margin_start(BODY_INSET - 8)
        .margin_end(BODY_INSET)
        .valign(gtk::Align::Center)
        .build();
    let play = round_button(
        "media-playback-start-symbolic",
        &format!("Play {artist}"),
        &["suggested-action", "artist-sticky-play"],
    );
    play.set_action_name(Some("win.artist-play"));
    play.set_action_target_value(Some(&artist.to_variant()));
    row.append(&play);
    let name = gtk::Label::builder()
        .label(artist)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    name.add_css_class("artist-sticky-name");
    row.append(&name);

    let bar = gtk::Overlay::new();
    bar.set_child(Some(&tint));
    bar.add_overlay(&row);
    bar.set_valign(gtk::Align::Start);
    bar.set_size_request(-1, STICKY_HEIGHT);
    bar.add_css_class("artist-sticky");
    bar.set_opacity(0.0);
    bar.set_can_target(false);
    bar.set_visible(false);
    (bar, tint)
}

fn follow_scroll(page: &Rc<Page>) {
    let weak = Rc::downgrade(page);
    page.scroll.vadjustment().connect_value_changed(move |adjustment| {
        let Some(page) = weak.upgrade() else { return };
        let offset = adjustment.value();
        page.hero.follow_scroll(offset);
        let start = page.hero.height() as f64 - STICKY_LEAD;
        let shown = ((offset - start) / STICKY_FADE).clamp(0.0, 1.0);
        if (page.sticky.opacity() - shown).abs() > f64::EPSILON {
            page.sticky.set_visible(shown > 0.0);
            page.sticky.set_opacity(shown);
            page.sticky.set_can_target(shown > 0.5);
        }
    });
}

/// Until a photo arrives, the hero shows the artist's signature record, its
/// sleeve over its own blurred wash, and the page takes its colour.
fn show_stand_in(
    page: &Rc<Page>,
    library: &Library,
    credited: &[usize],
    appears_on: &[usize],
    signature: Option<usize>,
) {
    let Some(index) = signature
        .or_else(|| credited.first().copied())
        .or_else(|| appears_on.first().copied())
    else {
        return;
    };
    let album = &library.albums[index];
    {
        let weak = Rc::downgrade(page);
        page.ui.core.artwork.request_backdrop(&album.title, &album.artist, move |texture| {
            if let (Some(page), Some(texture)) = (weak.upgrade(), texture) {
                page.hero.set_stand_in(texture.clone().upcast());
            }
        });
    }
    let weak = Rc::downgrade(page);
    page.ui
        .core
        .artwork
        .request(&album.title, &album.artist, SLEEVE_SIDE, move |texture, colour| {
            let Some(page) = weak.upgrade() else { return };
            if let Some(texture) = texture {
                page.hero.set_sleeve(texture.clone().upcast());
            }
            if let Some(colour) = colour.filter(|_| !page.has_photo_colour.get()) {
                page.set_colour(colour);
            }
        });
}

impl Page {
    fn set_colour(&self, colour: (u8, u8, u8)) {
        *self.dominant.borrow_mut() = Some(colour);
        self.backdrop.queue_draw();
        self.sticky_tint.queue_draw();
    }

    fn receive(self: &Rc<Self>, arrival: Arrival) {
        match arrival {
            Arrival::Listening(listening) => self.show_listening(&listening),
            Arrival::Photo(photo) => {
                let texture = photo.texture();
                self.hero.set_photo(texture.clone());
                self.about.set_photo(&texture);
                self.has_photo_colour.set(true);
                self.set_colour(photo.dominant);
            }
            Arrival::Bio(bio) => self.about.set_bio(bio.as_deref()),
            Arrival::Popular(names) => {
                self.songs.set_popular(songs::owned_in_order(&names, &self.owned));
            }
            Arrival::Facts {
                tags,
                similar,
                reach,
            } => self.show_facts(tags, &similar, reach),
            Arrival::Portrait(name, photo) => {
                if let Some(row) = self.similar.borrow().as_ref() {
                    row.set_photo(&name, &photo.texture());
                }
            }
        }
    }

    fn show_listening(&self, listening: &ArtistListening) {
        self.hero.set_mine(listening::hero_line(listening).as_deref());
        let names: Vec<String> = listening.songs.iter().map(|song| song.title.clone()).collect();
        let plays: HashMap<String, i64> = listening
            .songs
            .iter()
            .map(|song| (song.title_key.clone(), song.plays))
            .collect();
        self.songs
            .set_mine(songs::owned_in_order(&names, &self.owned), plays);
        if let Some(card) = listening::card(&self.ui, &self.artist, listening, &self.owned) {
            self.listening_slot.append(&card);
        }
    }

    fn show_facts(self: &Rc<Self>, tags: Vec<String>, similar: &[String], reach: Option<(u64, u64)>) {
        let tags = if tags.is_empty() {
            library_genre_fallback(&self.ui, &self.artist)
        } else {
            tags
        };
        self.hero.set_tags(&tags);
        self.about.set_tags(&tags);
        self.about.set_reach(reach);
        if let Some((listeners, _)) = reach.filter(|(listeners, _)| *listeners > 0) {
            let listeners = format!("{} listeners", people::compact(listeners));
            let meta = if self.meta.is_empty() {
                listeners
            } else {
                format!("{}  ·  {listeners}", self.meta)
            };
            self.hero.set_meta(&meta);
        }

        let library = self.ui.core.library.borrow().clone();
        let albums: HashMap<String, usize> = library
            .artists
            .iter()
            .map(|entry| (entry.name.clone(), entry.album_count))
            .collect();
        let names: Vec<(String, usize)> = similar
            .iter()
            .map(|name| (name.clone(), albums.get(name).copied().unwrap_or(0)))
            .collect();
        let open: Rc<dyn Fn(&str)> = {
            let ui = Rc::clone(&self.ui);
            Rc::new(move |name: &str| push_artist_page(&ui, name))
        };
        if let Some(row) = people::SimilarRow::new(&self.artist, &names, &self.scroll, open) {
            self.similar_slot.append(&row.widget);
            *self.similar.borrow_mut() = Some(row);
        }
    }
}

/// Reads the history on one worker thread and the photo and what Last.fm
/// knows on another, handing each to the page as it lands: ranking the artist
/// reads the whole history, which must not hold up the photo.
fn gather(page: &Rc<Page>, library: &Library) {
    let artist = page.artist.clone();
    let db_path = page.ui.core.db_path.clone();
    let session_key = page.ui.core.session.borrow().as_ref().map(|s| s.key.clone());
    let library_artists: Vec<String> = library.artists.iter().map(|a| a.name.clone()).collect();
    let (tx, rx) = async_channel::unbounded::<Arrival>();
    {
        let (tx, artist, db_path) = (tx.clone(), artist.clone(), db_path.clone());
        std::thread::Builder::new()
            .name("flaccy-artist-history".into())
            .spawn(move || {
                if let Ok(db) = crate::db::Db::open(&db_path) {
                    let _ = tx.send_blocking(Arrival::Listening(db.artist_listening(&artist)));
                }
            })
            .ok();
    }
    std::thread::Builder::new()
        .name("flaccy-artist-page".into())
        .spawn(move || {
            let Ok(db) = crate::db::Db::open(&db_path) else {
                return;
            };
            if let Some(photo) = artist_photo(&db, &artist, PHOTO_MAX_SIDE) {
                if tx.send_blocking(Arrival::Photo(photo)).is_err() {
                    return;
                }
            }
            let client = crate::lastfm::LastFmClient::new(session_key);
            let popular = client
                .as_ref()
                .and_then(|c| c.fetch_artist_top_tracks(&artist, POPULAR_FETCH).ok())
                .unwrap_or_default();
            if tx.send_blocking(Arrival::Popular(popular)).is_err() {
                return;
            }
            let tags = client
                .as_ref()
                .and_then(|c| c.fetch_top_tags(&artist, TAG_LIMIT).ok())
                .unwrap_or_default();
            let reach = client.as_ref().and_then(|c| c.fetch_artist_reach(&artist).ok());
            let similar: Vec<String> = crate::enrichment::similar_in_library_blocking(
                &db,
                client.as_ref(),
                &artist,
                &library_artists,
            )
            .into_iter()
            .filter(|(name, _)| !name.eq_ignore_ascii_case(&artist))
            .map(|(name, _)| name)
            .take(SIMILAR_LIMIT)
            .collect();
            let facts = Arrival::Facts {
                tags,
                similar: similar.clone(),
                reach,
            };
            if tx.send_blocking(facts).is_err() {
                return;
            }
            for name in similar {
                if tx.is_closed() {
                    return;
                }
                if let Some(photo) = artist_photo(&db, &name, PORTRAIT_SIDE) {
                    let _ = tx.send_blocking(Arrival::Portrait(name, photo));
                }
            }
        })
        .ok();
    listen(page, rx);
}

fn listen(page: &Rc<Page>, rx: async_channel::Receiver<Arrival>) {
    let weak = Rc::downgrade(page);
    glib::spawn_future_local(async move {
        while let Ok(arrival) = rx.recv().await {
            let Some(page) = weak.upgrade() else { break };
            page.receive(arrival);
        }
    });
}

/// When the enrichment job finds this artist's photo or biography while the
/// page is open, the page picks them up.
fn refresh_when_enriched(page: &Rc<Page>) {
    let weak = Rc::downgrade(page);
    page.ui
        .core
        .hub
        .subscribe_widget(&page.hero.widget, move |_, event| {
            let AppEvent::ArtistEnriched { name } = event else {
                return;
            };
            let Some(page) = weak.upgrade() else { return };
            if *name != page.artist {
                return;
            }
            let artist = page.artist.clone();
            let db_path = page.ui.core.db_path.clone();
            let wants_photo = !page.hero.has_photo();
            let (tx, rx) = async_channel::unbounded::<Arrival>();
            std::thread::Builder::new()
                .name("flaccy-artist-enriched".into())
                .spawn(move || {
                    let Ok(db) = crate::db::Db::open(&db_path) else {
                        return;
                    };
                    let _ = tx.send_blocking(Arrival::Bio(db.artist_bio(&artist)));
                    if wants_photo {
                        if let Some(photo) = artist_photo(&db, &artist, PHOTO_MAX_SIDE) {
                            let _ = tx.send_blocking(Arrival::Photo(photo));
                        }
                    }
                })
                .ok();
            listen(&page, rx);
        });
}

/// Offline fallback for the genres: the distinct genres of the artist's
/// library albums, used when Last.fm has no top tags for the artist.
fn library_genre_fallback(ui: &Rc<Ui>, artist: &str) -> Vec<String> {
    let library = ui.core.library.borrow().clone();
    let key = crate::hygiene::artist_key(artist);
    let mut seen = std::collections::HashSet::new();
    library
        .albums
        .iter()
        .filter(|album| crate::hygiene::artist_key(&album.artist) == key)
        .filter_map(|album| album.genre.clone())
        .filter(|genre| !genre.is_empty() && seen.insert(genre.to_lowercase()))
        .take(TAG_LIMIT)
        .collect()
}

/// The artist's photo, from the XDG cache or downloaded into it, decoded no
/// larger than `max_side`.
fn artist_photo(db: &crate::db::Db, artist: &str, max_side: u32) -> Option<Photo> {
    let url = db
        .artist_image_url(artist)
        .filter(|url| !url.contains(LASTFM_PLACEHOLDER_HASH))?;
    let data = photo_bytes(artist, &url)?;
    let decoded = image::load_from_memory(&data).ok()?;
    let sized = if decoded.width().max(decoded.height()) > max_side {
        decoded.thumbnail(max_side, max_side)
    } else {
        decoded
    };
    let rgba = sized.to_rgba8();
    let (width, height) = rgba.dimensions();
    let sample = image::imageops::thumbnail(&rgba, 48, 48);
    let dominant = crate::palette::dominant_color(sample.as_raw(), sample.width(), sample.height());
    Some(Photo {
        width,
        height,
        rgba: rgba.into_raw(),
        dominant,
    })
}

fn photo_bytes(artist: &str, url: &str) -> Option<Vec<u8>> {
    let cache_dir = dirs::cache_dir()?.join("flaccy").join("artists");
    let _ = std::fs::create_dir_all(&cache_dir);
    let cache_path = cache_dir.join(format!("{:016x}", crate::palette::fnv1a_64(artist)));
    if let Ok(data) = std::fs::read(&cache_path) {
        return Some(data);
    }
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
    Some(data)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn song(title: &str) -> Track {
        Track {
            id: 0,
            rel_path: format!("A/{title}.flac"),
            title: title.to_string(),
            artist: "A".to_string(),
            album: "Album".to_string(),
            album_artist: None,
            track_number: 1,
            duration: 240.0,
            codec: None,
            bit_depth: None,
            sample_rate: None,
            channels: None,
            loved: false,
            play_count: 0,
            date_added: 0,
            last_played: None,
            revision: 1,
            revised_at: None,
            file_modified_ms: None,
            disc_number: None,
        }
    }

    fn album(title: &str, songs: usize) -> crate::library::Album {
        crate::library::Album {
            title: title.to_string(),
            artist: "A".to_string(),
            year: None,
            genre: None,
            tracks: (0..songs).map(|n| song(&format!("{title} {n}"))).collect(),
        }
    }

    #[test]
    fn the_facts_line_counts_what_the_library_holds() {
        let mut library = Library::empty();
        library.albums = vec![album("LP", 10), album("Single", 1), album("LP2", 9)];
        assert_eq!(facts_line(&library, &[], &[], &[]), "");
        assert_eq!(facts_line(&library, &[], &[1, 2], &[]), "Appears on 2 albums");
        assert_eq!(facts_line(&library, &[0], &[], &[]), "1 album");
        assert_eq!(facts_line(&library, &[1], &[], &[]), "1 release");
        assert_eq!(facts_line(&library, &[0, 2], &[1], &[]), "2 albums");
        assert_eq!(facts_line(&library, &[0, 1, 2], &[], &[]), "3 releases");
        let owned = vec![song("x"), song("y")];
        assert_eq!(facts_line(&library, &[0], &[], &owned), "1 album  ·  2 songs  ·  8 min");
    }
}
