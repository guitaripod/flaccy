//! The search results page: what the window's search box finds across the
//! whole library when the page behind it (Home, Stats, Wantlist, Downloads,
//! Guide) has no list of its own to filter. Artists, albums, songs and
//! playlists are shown together, best match first; Enter in the search box
//! opens the first of them.
//!
//! The page is rebuilt only when the query or the library changes and only
//! while it is on screen, and it holds no timer or tick callback.

use crate::events::AppEvent;
use crate::home_data::{AlbumCard, Cover};
use crate::library::{format_time, ArtistEntry, Library, Track};
use crate::search::{self, PlaylistName, Results, TopHit};
use crate::ui::home_parts as parts;
use crate::ui::playlists::{self, PlaylistCard};
use crate::ui::{albums, artist_page, artists, artwork, context, Ui};
use adw::prelude::*;
use gtk::{gdk, pango};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

pub const PAGE: &str = "search";

const CONTENT_MAX_WIDTH: i32 = 1240;
const ARTIST_AVATAR: i32 = 104;
const SONG_THUMB: i32 = 40;
const PLAYLIST_TILE: i32 = 136;
const RESULTS: &str = "results";
const NOTHING: &str = "nothing";

/// The pages that filter their own list by the search box. Searching from any
/// other page shows the results page instead.
pub fn page_filters_itself(name: &str) -> bool {
    matches!(name, "albums" | "songs" | "artists" | "playlists")
}

struct State {
    ui: Rc<Ui>,
    stack: gtk::Stack,
    scroll: gtk::ScrolledWindow,
    body: gtk::Box,
    nothing: adw::StatusPage,
    shown_for: RefCell<Option<(String, *const Library)>>,
    stale: Cell<bool>,
    playlists: RefCell<Vec<PlaylistCard>>,
    artist_covers: RefCell<HashMap<String, (String, String)>>,
    covers_from: crate::filters::BuiltFrom,
    results: RefCell<Results>,
}

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let body = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(28)
        .margin_top(24)
        .margin_bottom(32)
        .margin_start(24)
        .margin_end(24)
        .build();
    let clamp = adw::Clamp::builder()
        .maximum_size(CONTENT_MAX_WIDTH)
        .child(&body)
        .build();
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(&clamp)
        .build();
    ui.register_scroller(&scroll);
    let nothing = adw::StatusPage::builder()
        .icon_name("system-search-symbolic")
        .title("No Results")
        .vexpand(true)
        .build();
    let stack = gtk::Stack::builder()
        .hhomogeneous(false)
        .vhomogeneous(false)
        .build();
    stack.add_named(&scroll, Some(RESULTS));
    stack.add_named(&nothing, Some(NOTHING));

    let state = Rc::new(State {
        ui: Rc::clone(ui),
        stack: stack.clone(),
        scroll,
        body,
        nothing,
        shown_for: RefCell::new(None),
        stale: Cell::new(true),
        playlists: RefCell::new(Vec::new()),
        artist_covers: RefCell::new(HashMap::new()),
        covers_from: crate::filters::BuiltFrom::default(),
        results: RefCell::new(Results::default()),
    });
    {
        let state = Rc::clone(&state);
        stack.connect_map(move |_| {
            state.stale.set(true);
            state.render();
        });
    }
    {
        let state = Rc::clone(&state);
        ui.core.hub.subscribe_widget(&stack, move |stack, event| match event {
            AppEvent::SearchChanged(_) if stack.is_mapped() => state.render(),
            AppEvent::LibraryReloaded | AppEvent::CleanLibraryChanged => {
                state.stale.set(true);
                if stack.is_mapped() {
                    state.render();
                }
            }
            AppEvent::SearchSubmitted if stack.is_mapped() => state.open_top_hit(),
            _ => {}
        });
    }
    stack.upcast()
}

impl State {
    /// Reads what only changes with the library or between visits: the
    /// playlists and the album each artist is pictured by.
    fn refresh_sources(&self, library: &Rc<Library>) {
        if !self.stale.replace(false) {
            return;
        }
        *self.playlists.borrow_mut() = playlists::load_cards(&self.ui);
        if !self.covers_from.is(library) {
            *self.artist_covers.borrow_mut() = artists::representative_covers(&library.albums);
            self.covers_from.set(library);
        }
        *self.shown_for.borrow_mut() = None;
    }

    fn render(&self) {
        let query = self.ui.query.borrow().trim().to_string();
        let library = self.ui.core.library.borrow().clone();
        self.refresh_sources(&library);
        let shown_for = (query.clone(), Rc::as_ptr(&library));
        if self.shown_for.borrow().as_ref() == Some(&shown_for) {
            return;
        }
        let results = {
            let cards = self.playlists.borrow();
            let names: Vec<PlaylistName> = cards
                .iter()
                .enumerate()
                .map(|(index, card)| PlaylistName {
                    index,
                    name: &card.name,
                })
                .collect();
            let hide_duplicates = self.ui.core.config.borrow().clean_library;
            search::find(&library, &names, &query, hide_duplicates)
        };
        while let Some(child) = self.body.first_child() {
            self.body.remove(&child);
        }
        if results.is_empty() {
            self.nothing.set_description(Some(&nothing_found_text(&query, &library)));
            self.stack.set_visible_child_name(NOTHING);
        } else {
            self.fill(&results);
            self.scroll.vadjustment().set_value(0.0);
            self.stack.set_visible_child_name(RESULTS);
        }
        *self.results.borrow_mut() = results;
        *self.shown_for.borrow_mut() = Some(shown_for);
    }

    fn fill(&self, results: &Results) {
        let ui = &self.ui;
        if !results.artists.shown.is_empty() {
            let covers = self.artist_covers.borrow();
            let tiles = results
                .artists
                .shown
                .iter()
                .map(|artist| {
                    let cover = covers.get(&crate::hygiene::artist_key(&artist.name));
                    artist_tile(ui, artist, cover)
                })
                .collect();
            let shelf = parts::shelf(tiles, &self.scroll);
            self.section("Artists", "artists", &results.artists, &shelf);
        }
        if !results.albums.shown.is_empty() {
            let tiles = results
                .albums
                .shown
                .iter()
                .map(|album| {
                    let card = AlbumCard {
                        album: album.clone(),
                        badge: None,
                    };
                    parts::album_tile(ui, &card)
                })
                .collect();
            let shelf = parts::shelf(tiles, &self.scroll);
            self.section("Albums", "albums", &results.albums, &shelf);
        }
        if !results.songs.shown.is_empty() {
            let list = song_list(ui, &results.songs.shown);
            self.section("Songs", "songs", &results.songs, &list);
        }
        if !results.playlists.shown.is_empty() {
            let cards = self.playlists.borrow();
            let tiles = results
                .playlists
                .shown
                .iter()
                .filter_map(|index| cards.get(*index))
                .map(|card| playlist_tile(ui, card))
                .collect();
            let shelf = parts::shelf(tiles, &self.scroll);
            self.section("Playlists", "playlists", &results.playlists, &shelf);
        }
    }

    /// Adds one kind of result under its heading. When more matched than are
    /// shown, the heading links to that kind's own page, which lists them all
    /// under the same search.
    fn section<T>(
        &self,
        title: &str,
        page: &'static str,
        found: &search::Found<T>,
        content: &impl IsA<gtk::Widget>,
    ) {
        let section = gtk::Box::new(gtk::Orientation::Vertical, 10);
        let label = show_all_text(found.total);
        let link: Option<parts::HeadingLink> = (found.total > found.shown.len()).then(|| {
            let window = self.ui.window.clone();
            let open: Box<dyn Fn()> = Box::new(move || {
                gtk::prelude::ActionGroupExt::activate_action(
                    &window,
                    "show-page",
                    Some(&page.to_variant()),
                );
            });
            (label.as_str(), open)
        });
        section.append(&parts::section_heading(title, link));
        section.append(content);
        self.body.append(&section);
    }

    fn open_top_hit(&self) {
        self.render();
        let results = self.results.borrow();
        let ui = &self.ui;
        match results.top_hit() {
            Some(TopHit::Artist) => {
                if let Some(artist) = results.artists.shown.first() {
                    artist_page::push_artist_page(ui, &artist.name);
                }
            }
            Some(TopHit::Album) => {
                if let Some(album) = results.albums.shown.first() {
                    albums::push_album_detail(ui, album);
                }
            }
            Some(TopHit::Song) => ui.core.play_tracks(results.songs.shown.clone(), 0),
            Some(TopHit::Playlist) => {
                let cards = self.playlists.borrow();
                let first = results.playlists.shown.first().and_then(|index| cards.get(*index));
                if let Some(card) = first {
                    playlists::push_playlist_detail(ui, card.id);
                }
            }
            None => {}
        }
    }
}

fn show_all_text(total: usize) -> String {
    format!("Show All {}", flaccy_shared::load_progress::group_digits(total))
}

/// What the empty page says: what was looked for, why nothing came back and
/// what to try.
fn nothing_found_text(query: &str, library: &Library) -> String {
    if library.tracks.is_empty() {
        return "Your library has no music yet. Add music to your music folder, then choose Rescan Library.".to_string();
    }
    format!(
        "No artist, album, song or playlist in your library has every word of “{query}”. Check the spelling or search for fewer words."
    )
}

fn caption(text: &str) -> gtk::Label {
    let label = gtk::Label::builder()
        .label(text)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(1)
        .width_chars(1)
        .build();
    label.add_css_class("dim");
    label.add_css_class("caption");
    label
}

fn artist_tile(ui: &Rc<Ui>, artist: &ArtistEntry, cover: Option<&(String, String)>) -> gtk::Widget {
    let avatar = adw::Avatar::new(ARTIST_AVATAR, Some(&artist.name), true);
    avatar.set_halign(gtk::Align::Center);
    if let Some((title, album_artist)) = cover {
        let weak = avatar.downgrade();
        ui.core.artwork.request_for(
            &avatar,
            title,
            album_artist,
            ARTIST_AVATAR as u32,
            move |texture, _| {
                if let (Some(avatar), Some(texture)) = (weak.upgrade(), texture) {
                    avatar.set_custom_image(Some(texture));
                }
            },
        );
    }
    let name = gtk::Label::builder()
        .label(&artist.name)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(1)
        .width_chars(1)
        .justify(gtk::Justification::Center)
        .margin_top(6)
        .build();
    name.add_css_class("home-tile-title");
    let counts = caption(&artists::artist_counts_label(artist));
    counts.set_xalign(0.5);
    let content = gtk::Box::new(gtk::Orientation::Vertical, 2);
    content.set_size_request(PLAYLIST_TILE, -1);
    content.append(&avatar);
    content.append(&name);
    content.append(&counts);
    let button = gtk::Button::builder().child(&content).build();
    button.add_css_class("flat");
    button.add_css_class("home-tile");
    button.set_tooltip_text(Some(&artist.name));
    button.update_property(&[gtk::accessible::Property::Label(&artist.name)]);
    {
        let (ui, name) = (Rc::clone(ui), artist.name.clone());
        button.connect_clicked(move |_| artist_page::push_artist_page(&ui, &name));
    }
    context::attach_artist_context_menu(&button, artist.name.clone());
    button.upcast()
}

fn playlist_tile(ui: &Rc<Ui>, card: &PlaylistCard) -> gtk::Widget {
    let id = card.id;
    let subtitle = card.subtitle();
    let tile = parts::tile(
        ui,
        &Cover::Playlist {
            id,
            name: card.name.clone(),
            albums: card.covers.clone(),
        },
        PLAYLIST_TILE,
        parts::TileWords {
            title: &card.name,
            subtitle: &subtitle,
            badge: None,
        },
        {
            let ui = Rc::clone(ui);
            move || playlists::push_playlist_detail(&ui, id)
        },
        {
            let ui = Rc::clone(ui);
            move || playlists::play_playlist(&ui, id, false)
        },
    );
    tile.upcast()
}

/// The found songs as rows. Activating one plays the found songs from it, so
/// the rest of the results follow as the queue.
fn song_list(ui: &Rc<Ui>, songs: &[Track]) -> gtk::ListBox {
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .build();
    list.add_css_class("boxed-list");
    list.add_css_class("search-songs");
    for track in songs {
        list.append(&song_row(ui, track));
    }
    let ui = Rc::clone(ui);
    let songs = songs.to_vec();
    list.connect_row_activated(move |_, row| {
        ui.core.play_tracks(songs.clone(), row.index().max(0) as usize);
    });
    list
}

fn song_row(ui: &Rc<Ui>, track: &Track) -> gtk::ListBoxRow {
    let row_box = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .margin_top(6)
        .margin_bottom(6)
        .margin_start(12)
        .margin_end(14)
        .build();
    let thumb = gtk::Picture::builder()
        .width_request(SONG_THUMB)
        .height_request(SONG_THUMB)
        .content_fit(gtk::ContentFit::Cover)
        .valign(gtk::Align::Center)
        .build();
    thumb.set_overflow(gtk::Overflow::Hidden);
    thumb.add_css_class("cover-thumb");
    let credit = track.credit().to_string();
    thumb.set_paintable(Some(
        &ui.core.artwork.placeholder(&format!("{}|{}", track.album, credit)),
    ));
    artwork::follow_picture(&ui.core, &thumb, &track.album, &credit, SONG_THUMB as u32);
    row_box.append(&thumb);

    let words = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(1)
        .valign(gtk::Align::Center)
        .hexpand(true)
        .build();
    let title = gtk::Label::builder()
        .label(&track.title)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    title.add_css_class("home-row-title");
    words.append(&title);
    words.append(&caption(&song_caption(track)));
    row_box.append(&words);

    if track.loved {
        let heart = gtk::Image::from_icon_name("emblem-favorite-symbolic");
        heart.add_css_class("artist-song-loved");
        heart.set_tooltip_text(Some("Loved"));
        row_box.append(&heart);
    }
    let duration = gtk::Label::builder()
        .label(format_time(track.duration))
        .xalign(1.0)
        .width_chars(5)
        .build();
    duration.add_css_class("duration-label");
    row_box.append(&duration);

    let row = gtk::ListBoxRow::builder().child(&row_box).build();
    row.set_cursor(gdk::Cursor::from_name("pointer", None).as_ref());
    context::attach_track_context_menu(&row, &ui.core, track.rel_path.clone());
    row
}

fn song_caption(track: &Track) -> String {
    match (track.artist.is_empty(), track.album.is_empty()) {
        (false, false) => format!("{} · {}", track.artist, track.album),
        (false, true) => track.artist.clone(),
        (true, false) => track.album.clone(),
        (true, true) => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_four_library_lists_filter_themselves() {
        for page in ["albums", "songs", "artists", "playlists"] {
            assert!(page_filters_itself(page), "{page}");
        }
        for page in ["home", "stats", "wantlist", "downloads", "guide", PAGE] {
            assert!(!page_filters_itself(page), "{page}");
        }
    }

    #[test]
    fn the_show_all_link_counts_what_matched() {
        assert_eq!(show_all_text(13), "Show All 13");
        assert_eq!(show_all_text(1204), "Show All 1\u{202f}204");
    }
}
