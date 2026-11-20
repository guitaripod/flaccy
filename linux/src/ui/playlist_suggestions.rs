//! The Suggested Songs shelf under a playlist's songs: songs from the
//! person's own library that fit the playlist, each with a button that adds it.
//! Nothing is added on its own; Refresh shows the next ones and the eye hides
//! the shelf on every playlist, as on the iPhone and the Mac. The ranking is
//! `flaccy_shared::playlist_suggestions`; similar artists come from the
//! Last.fm cache the stations fill, never the network.

use crate::app::AppCore;
use crate::events::AppEvent;
use crate::library::Track;
use crate::ui::mosaic::Mosaic;
use crate::ui::Ui;
use adw::prelude::*;
use flaccy_shared::playlist_suggestions::{self, SimilarArtist, Song};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

pub const TITLE: &str = "Suggested Songs";
pub const SUBTITLE: &str = "From your library, never added on their own";
pub const HIDE: &str = "Hide Suggested Songs";
pub const SHOW: &str = "Show Suggested Songs";
const SEED_ARTISTS: usize = 5;
const THUMB_PX: i32 = 40;

pub struct Shelf {
    pub root: gtk::Box,
    list: gtk::ListBox,
    ui: Rc<Ui>,
    playlist_id: i64,
    page: Cell<usize>,
    basis: RefCell<Vec<String>>,
    playlist: RefCell<Vec<Track>>,
}

impl Shelf {
    pub fn new(ui: &Rc<Ui>, playlist_id: i64) -> Rc<Self> {
        let title = gtk::Label::builder().label(TITLE).xalign(0.0).build();
        title.add_css_class("title-3");
        let subtitle = gtk::Label::builder().label(SUBTITLE).xalign(0.0).wrap(true).build();
        subtitle.add_css_class("dim");
        subtitle.add_css_class("caption");
        let text = gtk::Box::new(gtk::Orientation::Vertical, 2);
        text.set_hexpand(true);
        text.append(&title);
        text.append(&subtitle);

        let refresh = gtk::Button::from_icon_name("view-refresh-symbolic");
        refresh.add_css_class("flat");
        refresh.add_css_class("circular");
        refresh.set_tooltip_text(Some("Refresh"));
        refresh.update_property(&[gtk::accessible::Property::Label("Refresh")]);
        let hide = gtk::Button::from_icon_name("view-conceal-symbolic");
        hide.add_css_class("flat");
        hide.add_css_class("circular");
        hide.set_tooltip_text(Some(HIDE));
        hide.update_property(&[gtk::accessible::Property::Label(HIDE)]);

        let header = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        header.append(&text);
        header.append(&refresh);
        header.append(&hide);

        let list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .build();
        list.add_css_class("boxed-list");

        let root = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(10)
            .margin_top(28)
            .visible(false)
            .build();
        root.append(&header);
        root.append(&list);

        let shelf = Rc::new(Shelf {
            root,
            list,
            ui: Rc::clone(ui),
            playlist_id,
            page: Cell::new(0),
            basis: RefCell::new(Vec::new()),
            playlist: RefCell::new(Vec::new()),
        });
        {
            let shelf = Rc::downgrade(&shelf);
            refresh.connect_clicked(move |_| {
                if let Some(shelf) = shelf.upgrade() {
                    shelf.page.set(shelf.page.get() + 1);
                    shelf.rebuild();
                }
            });
        }
        {
            let ui = Rc::clone(ui);
            hide.connect_clicked(move |_| set_shown(&ui.core, false));
        }
        {
            let weak = Rc::downgrade(&shelf);
            ui.core.hub.subscribe_widget(&shelf.root, move |_, event| {
                if let (AppEvent::PlaylistSuggestionsToggled, Some(shelf)) = (event, weak.upgrade()) {
                    shelf.basis.borrow_mut().clear();
                    let playlist = shelf.playlist.borrow().clone();
                    shelf.update(&playlist);
                }
            });
        }
        shelf
    }

    /// Takes the playlist's songs as the page now lists them and builds the
    /// shelf again when they changed, so an added suggestion makes room for
    /// the next one.
    pub fn update(&self, playlist: &[Track]) {
        *self.playlist.borrow_mut() = playlist.to_vec();
        let mut basis: Vec<String> = playlist.iter().map(|track| track.rel_path.clone()).collect();
        basis.sort();
        if !is_shown(&self.ui.core) || playlist.is_empty() {
            self.basis.borrow_mut().clear();
            self.root.set_visible(false);
            return;
        }
        if *self.basis.borrow() == basis {
            return;
        }
        *self.basis.borrow_mut() = basis;
        self.rebuild();
    }

    fn rebuild(&self) {
        let picks = self.suggestions();
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
        for track in &picks {
            self.list.append(&self.row(track));
        }
        self.root.set_visible(!picks.is_empty());
    }

    fn suggestions(&self) -> Vec<Track> {
        let playlist = self.playlist.borrow();
        let library = self.ui.core.library.borrow();
        let songs: Vec<Song> = playlist.iter().map(song).collect();
        let mut similar: HashMap<String, Vec<SimilarArtist>> = HashMap::new();
        for seed in playlist_suggestions::seed_artists(&songs, SEED_ARTISTS) {
            let matches = self
                .ui
                .core
                .db
                .similar_artists(&seed)
                .into_iter()
                .map(|(name, match_score, _)| SimilarArtist { name, match_score })
                .collect();
            similar.insert(seed, matches);
        }
        let pool: Vec<Song> = library.tracks.iter().map(song).collect();
        let files = playlist_suggestions::suggest(
            &songs,
            &pool,
            &similar,
            self.page.get(),
            playlist_suggestions::PAGE_SIZE,
        );
        let by_path: HashMap<&str, &Track> = library
            .tracks
            .iter()
            .map(|track| (track.rel_path.as_str(), track))
            .collect();
        files
            .iter()
            .filter_map(|file| by_path.get(file.as_str()).map(|track| (*track).clone()))
            .collect()
    }

    fn row(&self, track: &Track) -> gtk::ListBoxRow {
        let thumb = Mosaic::new();
        thumb.set_fixed_size(THUMB_PX);
        thumb.widget().set_valign(gtk::Align::Center);
        thumb.widget().add_css_class("cover-thumb");
        let album = (track.album.clone(), track.album_artist.clone().unwrap_or_else(|| track.artist.clone()));
        let seed = format!("{}|{}", album.0, album.1);
        thumb.set_covers(&self.ui, &seed, std::slice::from_ref(&album), None);

        let title = gtk::Label::builder()
            .label(&track.title)
            .xalign(0.0)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .build();
        let detail_text = if track.album.trim().is_empty() {
            track.artist.clone()
        } else {
            format!("{} · {}", track.artist, track.album)
        };
        let detail = gtk::Label::builder()
            .label(&detail_text)
            .xalign(0.0)
            .ellipsize(gtk::pango::EllipsizeMode::End)
            .build();
        detail.add_css_class("dim");
        detail.add_css_class("caption");
        let text = gtk::Box::new(gtk::Orientation::Vertical, 2);
        text.set_hexpand(true);
        text.set_valign(gtk::Align::Center);
        text.append(&title);
        text.append(&detail);

        let label = format!("Add {} to the playlist", track.title);
        let add = gtk::Button::from_icon_name("list-add-symbolic");
        add.add_css_class("flat");
        add.add_css_class("circular");
        add.set_valign(gtk::Align::Center);
        add.set_tooltip_text(Some(&label));
        add.update_property(&[gtk::accessible::Property::Label(&label)]);
        {
            let ui = Rc::clone(&self.ui);
            let playlist_id = self.playlist_id;
            let rel_path = track.rel_path.clone();
            add.connect_clicked(move |_| crate::ui::playlists::add_to_playlist(&ui, playlist_id, &[rel_path.clone()]));
        }

        let row_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(12)
            .margin_top(8)
            .margin_bottom(8)
            .margin_start(12)
            .margin_end(12)
            .build();
        row_box.append(thumb.widget());
        row_box.append(&text);
        row_box.append(&add);
        let row = gtk::ListBoxRow::builder().child(&row_box).activatable(false).build();
        crate::ui::context::attach_track_context_menu(&row, &self.ui.core, track.rel_path.clone());
        row
    }
}

fn song(track: &Track) -> Song {
    Song {
        file: track.rel_path.clone(),
        title: track.title.clone(),
        artist: track.artist.clone(),
        album: track.album.clone(),
        loved: track.loved,
        play_count: track.play_count,
    }
}

pub fn is_shown(core: &AppCore) -> bool {
    !core.config.borrow().playlist_suggestions_hidden
}

/// Shows or hides the shelf on every playlist and tells the open pages.
pub fn set_shown(core: &Rc<AppCore>, shown: bool) {
    core.config.borrow_mut().playlist_suggestions_hidden = !shown;
    core.save_config();
    core.hub.emit(&AppEvent::PlaylistSuggestionsToggled);
    if !shown {
        core.toast("Suggested Songs hidden. Show them again from a playlist’s More menu.");
    }
}
