pub mod albums;
pub mod artists;
pub mod artwork;
pub mod cleanup;
pub mod context;
pub mod controls;
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
use std::cell::RefCell;
use std::rc::Rc;

pub struct Ui {
    pub core: Rc<AppCore>,
    pub nav: adw::NavigationView,
    pub shell: adw::NavigationView,
    pub window: adw::ApplicationWindow,
    pub query: Rc<RefCell<String>>,
}
