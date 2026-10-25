use crate::db::Db;
use crate::events::AppEvent;
use crate::filters;
use crate::library::Track;
use crate::suggested::{self, SuggestedPlaylist};
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

/// Everything the shelf's contents are computed from. Equal keys mean equal
/// shelves: the library's tracks, the scrobble history (which only changes
/// outside the library through an import) and the day, which the date-based
/// windows and Tonight's Spin turn on.
#[derive(Clone, Copy, PartialEq, Eq)]
struct ShelfKey {
    tracks: u64,
    history: u32,
    day: i64,
}

struct Shelf {
    ui: Rc<Ui>,
    holder: gtk::Box,
    shelf: gtk::Box,
    cards: gtk::Box,
    computing: Cell<bool>,
    rerun_wanted: Cell<bool>,
    requested: Cell<Option<ShelfKey>>,
    computed_once: Cell<bool>,
    history_epoch: Cell<u32>,
    stale: Cell<bool>,
    shown: RefCell<Vec<SuggestedPlaylist>>,
}

/// "Made for you" shelf on the Albums page: Heavy Rotation / On Repeat /
/// Rediscover cards computed off-main from local scrobbles.
pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let shelf = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .margin_top(20)
        .margin_start(24)
        .margin_end(24)
        .build();
    shelf.set_visible(false);

    let title = gtk::Label::builder()
        .label("MADE FOR YOU")
        .xalign(0.0)
        .build();
    title.add_css_class("stat-caption");
    shelf.append(&title);

    let cards = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(14)
        .build();
    // Horizontal scroller so three Made-for-You cards never force the albums
    // page wider than the window.
    let cards_scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Automatic)
        .vscrollbar_policy(gtk::PolicyType::Never)
        .hexpand(true)
        .propagate_natural_width(false)
        .propagate_natural_height(true)
        .child(&cards)
        .build();
    cards_scroll.add_css_class("suggested-scroll");
    shelf.append(&cards_scroll);
    shelf.set_hexpand(true);

    let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
    holder.append(&shelf);

    let state = Rc::new(Shelf {
        ui: Rc::clone(ui),
        holder: holder.clone(),
        shelf,
        cards,
        computing: Cell::new(false),
        rerun_wanted: Cell::new(false),
        requested: Cell::new(None),
        computed_once: Cell::new(false),
        history_epoch: Cell::new(0),
        stale: Cell::new(false),
        shown: RefCell::new(Vec::new()),
    });
    state.request();

    {
        let state = Rc::clone(&state);
        ui.core
            .hub
            .subscribe_widget(&holder, move |_, event| match event {
                AppEvent::LibraryReloaded => state.on_inputs_changed(),
                AppEvent::HistoryImport { done: true, .. } => {
                    state.history_epoch.set(state.history_epoch.get() + 1);
                    state.on_inputs_changed();
                }
                _ => {}
            });
    }
    {
        let state = Rc::clone(&state);
        holder.connect_map(move |_| {
            if state.stale.replace(false) {
                state.request();
            }
        });
    }

    holder.upcast()
}

impl Shelf {
    /// While the Albums page is off screen the shelf keeps what it shows and
    /// remembers that it is out of date, except for its very first fill, which
    /// happens in the background so the page never grows a shelf under the
    /// reader's eyes.
    fn on_inputs_changed(self: &Rc<Self>) {
        if self.holder.is_mapped() || !self.computed_once.get() {
            self.request();
        } else {
            self.stale.set(true);
        }
    }

    fn current_key(&self) -> ShelfKey {
        let library = self.ui.core.library.borrow().clone();
        ShelfKey {
            tracks: filters::library_signature(&library).tracks,
            history: self.history_epoch.get(),
            day: chrono::Utc::now().timestamp() / 86_400,
        }
    }

    /// Computes the shelf for the current library and history, unless that is
    /// what was last computed. The tracks are copied here, on the main thread,
    /// because the library cannot cross to the worker; that copy is the price
    /// of a recompute and is only paid when the tracks really changed.
    fn request(self: &Rc<Self>) {
        let key = self.current_key();
        if self.requested.get() == Some(key) {
            return;
        }
        if self.computing.get() {
            self.rerun_wanted.set(true);
            return;
        }
        let library = self.ui.core.library.borrow().clone();
        self.requested.set(Some(key));
        if library.tracks.is_empty() {
            self.show(Vec::new());
            return;
        }
        self.computing.set(true);
        let pool = library.tracks.clone();
        let db_path = self.ui.core.db_path.clone();
        let (tx, rx) = async_channel::bounded::<Option<Vec<SuggestedPlaylist>>>(1);
        std::thread::Builder::new()
            .name("flaccy-suggested".into())
            .spawn(move || {
                let playlists = Db::open(&db_path).ok().map(|db| {
                    let rows = db.fetch_all_scrobble_rows();
                    suggested::build(&pool, &rows, chrono::Utc::now().timestamp())
                });
                let _ = tx.send_blocking(playlists);
            })
            .ok();
        let state = Rc::clone(self);
        glib::spawn_future_local(async move {
            let computed = rx.recv().await.ok().flatten();
            state.computing.set(false);
            match computed {
                Some(playlists) => {
                    state.computed_once.set(true);
                    state.show(playlists);
                }
                None => state.requested.set(None),
            }
            if state.rerun_wanted.replace(false) {
                state.request();
            }
        });
    }

    /// Puts `playlists` on the shelf. A result identical to what is already
    /// there touches no widget.
    fn show(&self, playlists: Vec<SuggestedPlaylist>) {
        if same_shelf(&self.shown.borrow(), &playlists) {
            return;
        }
        while let Some(child) = self.cards.first_child() {
            self.cards.remove(&child);
        }
        if playlists.is_empty() {
            self.shelf.set_visible(false);
        } else {
            for playlist in &playlists {
                self.cards.append(&card(&self.ui, playlist));
            }
            self.shelf.set_visible(true);
        }
        *self.shown.borrow_mut() = playlists;
    }
}

/// Whether two shelves would draw and play the same: the same cards in the same
/// order holding the same songs in the same state.
fn same_shelf(shown: &[SuggestedPlaylist], next: &[SuggestedPlaylist]) -> bool {
    shown.len() == next.len()
        && shown.iter().zip(next).all(|(a, b)| {
            a.id == b.id
                && a.title == b.title
                && a.subtitle == b.subtitle
                && a.icon_name == b.icon_name
                && a.tracks.len() == b.tracks.len()
                && a.tracks
                    .iter()
                    .zip(&b.tracks)
                    .all(|(x, y)| filters::track_digest(x) == filters::track_digest(y))
        })
}

fn card(ui: &Rc<Ui>, playlist: &SuggestedPlaylist) -> gtk::Widget {
    let card = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .width_request(240)
        .hexpand(false)
        .build();
    card.add_css_class("suggested-card");

    let artwork = gtk::Picture::builder()
        .width_request(56)
        .height_request(56)
        .content_fit(gtk::ContentFit::Cover)
        .valign(gtk::Align::Center)
        .build();
    artwork.set_overflow(gtk::Overflow::Hidden);
    artwork.add_css_class("cover");
    if let Some(first) = playlist.tracks.first() {
        artwork.set_paintable(Some(
            &ui.core
                .artwork
                .placeholder(&format!("{}|{}", first.album, first.artist)),
        ));
        crate::ui::artwork::follow_picture(&ui.core, &artwork, &first.album, &first.artist, 56);
    }
    card.append(&artwork);

    let text_box = gtk::Box::new(gtk::Orientation::Vertical, 2);
    text_box.set_hexpand(true);
    text_box.set_valign(gtk::Align::Center);
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    header.append(&gtk::Image::from_icon_name(playlist.icon_name));
    let name = gtk::Label::builder()
        .label(&playlist.title)
        .xalign(0.0)
        .build();
    name.add_css_class("album-title");
    header.append(&name);
    text_box.append(&header);
    let subtitle = gtk::Label::builder()
        .label(format!(
            "{} · {} songs",
            playlist.subtitle,
            playlist.tracks.len()
        ))
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    subtitle.add_css_class("dim");
    subtitle.add_css_class("caption");
    text_box.append(&subtitle);
    card.append(&text_box);

    let play = gtk::Button::from_icon_name("media-playback-start-symbolic");
    play.add_css_class("circular");
    play.add_css_class("suggested-action");
    play.set_valign(gtk::Align::Center);
    play.set_tooltip_text(Some(&format!("Play {}", playlist.title)));
    {
        let ui = Rc::clone(ui);
        let tracks: Vec<Track> = playlist.tracks.clone();
        let title = playlist.title.clone();
        play.connect_clicked(move |_| {
            crate::logger::info("ui", &format!("suggested playlist play: {title}"));
            ui.core.play_tracks(tracks.clone(), 0);
        });
    }
    card.append(&play);

    let shuffle = gtk::Button::from_icon_name("media-playlist-shuffle-symbolic");
    shuffle.add_css_class("circular");
    shuffle.set_valign(gtk::Align::Center);
    shuffle.set_tooltip_text(Some(&format!("Shuffle {}", playlist.title)));
    {
        let ui = Rc::clone(ui);
        let tracks: Vec<Track> = playlist.tracks.clone();
        shuffle.connect_clicked(move |_| {
            if !ui.core.player.shuffle_enabled() {
                ui.core.player.toggle_shuffle();
            }
            let start = (crate::palette::fnv1a_64(&format!(
                "suggested{}",
                chrono::Utc::now().timestamp_micros()
            )) % tracks.len().max(1) as u64) as usize;
            ui.core.play_tracks(tracks.clone(), start);
        });
    }
    card.append(&shuffle);

    card.upcast()
}
