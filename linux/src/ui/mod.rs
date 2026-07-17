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
use gtk::glib;
use gtk::prelude::*;
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
