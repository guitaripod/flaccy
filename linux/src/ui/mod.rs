pub mod albums;
pub mod artists;
pub mod artwork;
pub mod cleanup;
pub mod context;
pub mod controls;
pub mod delete;
pub mod downloads;
pub mod guide;
pub mod lyrics_panel;
pub mod now_playing;
pub mod playlists;
pub mod queue_panel;
pub mod prefs;
pub mod songs;
pub mod suggested_shelf;
pub mod stats;
pub mod transport;
pub mod wantlist;
pub mod window;
pub mod year_in_music;

use crate::app::AppCore;
use adw::prelude::*;
use gtk::glib;
use std::cell::RefCell;
use std::rc::Rc;

pub struct Ui {
    pub core: Rc<AppCore>,
    pub nav: adw::NavigationView,
    pub shell: adw::NavigationView,
    pub window: adw::ApplicationWindow,
    pub query: Rc<RefCell<String>>,
    pub scrollers: RefCell<Vec<glib::WeakRef<gtk::ScrolledWindow>>>,
}

impl Ui {
    /// Enrolls a library page's vertical scroller as a target for the vim-style
    /// navigation keys (j/k/gg/G); registration order doubles as specificity,
    /// so detail pages pushed later win over the base page while both are
    /// briefly mapped during transitions.
    pub fn register_scroller(&self, scroll: &gtk::ScrolledWindow) {
        self.scrollers.borrow_mut().push(scroll.downgrade());
    }

    pub fn active_scroller(&self) -> Option<gtk::ScrolledWindow> {
        let mut scrollers = self.scrollers.borrow_mut();
        scrollers.retain(|weak| weak.upgrade().is_some());
        scrollers
            .iter()
            .rev()
            .filter_map(|weak| weak.upgrade())
            .find(|scroll| scroll.is_mapped())
    }
}

/// Closes the full-window Now Playing lens if it is covering the library so a
/// freshly pushed artist/album page is actually visible.
fn leave_now_playing(ui: &Rc<Ui>) {
    if ui
        .shell
        .visible_page()
        .and_then(|page| page.tag())
        .as_deref()
        == Some("now-playing")
    {
        ui.shell.pop();
    }
}

/// Opens the artist page for any artist credit (feat. credits collapse to the
/// lead artist). Toasts instead when the artist has nothing in the library —
/// reachable from Last.fm-sourced stats rows.
pub fn goto_artist(ui: &Rc<Ui>, artist: &str) {
    let lead = crate::hygiene::primary_artist(artist);
    let known = {
        let library = ui.core.library.borrow();
        library
            .albums
            .iter()
            .any(|album| crate::hygiene::artist_key(&album.artist) == crate::hygiene::artist_key(&lead))
    };
    if !known {
        ui.core.toast(&format!("{lead} isn't in your library"));
        return;
    }
    leave_now_playing(ui);
    artists::push_artist_page(ui, &lead);
}

/// Opens the album detail page for the album containing `rel_path`, falling
/// back to a title|artist key match for tracks that just left the library.
pub fn goto_album_of_track(ui: &Rc<Ui>, rel_path: &str) {
    let album = {
        let library = ui.core.library.borrow();
        library
            .albums
            .iter()
            .find(|album| album.tracks.iter().any(|track| track.rel_path == rel_path))
            .cloned()
            .or_else(|| {
                library
                    .track_by_rel_path(rel_path)
                    .and_then(|track| library.album_by_key(&format!("{}|{}", track.album, track.artist)))
                    .cloned()
            })
    };
    match album {
        Some(album) => {
            leave_now_playing(ui);
            albums::push_album_detail(ui, &album);
        }
        None => ui.core.toast("Album isn't in your library"),
    }
}
