pub mod albums;
pub mod artists;
pub mod artwork;
pub mod cleanup;
pub mod context;
pub mod controls;
pub mod debut;
pub mod delete;
pub mod downloads;
pub mod guide;
pub mod lyrics_panel;
pub mod lyrics_style;
pub mod now_playing;
pub mod playlists;
pub mod queue_panel;
pub mod prefs;
pub mod songs;
pub mod suggested_shelf;
pub mod stats;
pub mod transport;
pub mod video_view;
pub mod wantlist;
pub mod window;
pub mod year_in_music;

use crate::app::AppCore;
use adw::prelude::*;
use flaccy_shared::enrichment_job::Scope;
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

/// Frame deltas are clamped before anything integrates against them, so a
/// stalled frame can't blow a spring up.
pub const MAX_FRAME_DELTA: f64 = 1.0 / 30.0;

/// Runs a step function once per frame off a widget's own frame clock, which is
/// the only clock that stays in step with what is actually being painted.
/// Re-arming a running driver is a no-op, and `stop` tears the callback down so
/// a settled animation costs nothing.
#[derive(Default)]
pub struct FrameDriver {
    handle: RefCell<Option<gtk::TickCallbackId>>,
}

impl FrameDriver {
    pub fn start(&self, widget: &impl IsA<gtk::Widget>, step: impl Fn(f64) + 'static) {
        if self.handle.borrow().is_some() {
            return;
        }
        let previous: Cell<i64> = Cell::new(0);
        let handle = widget.as_ref().add_tick_callback(move |_, clock| {
            let now = clock.frame_time();
            let last = previous.replace(now);
            let delta = if last == 0 {
                MAX_FRAME_DELTA
            } else {
                ((now - last) as f64 / 1_000_000.0).clamp(0.0, MAX_FRAME_DELTA)
            };
            step(delta);
            glib::ControlFlow::Continue
        });
        *self.handle.borrow_mut() = Some(handle);
    }

    pub fn stop(&self) {
        if let Some(handle) = self.handle.borrow_mut().take() {
            handle.remove();
        }
    }
}

/// Revives every album the job wrote off and re-queues everything the database
/// then says is due, returning that count so the caller can name it. `exhausted`
/// is otherwise terminal by design, so this — and a producer version bump — are
/// the only two ways back.
pub fn retry_missing_artwork(ui: &Rc<Ui>) -> usize {
    ui.core.db.reset_exhausted(Scope::Album);
    let queued = ui.core.db.count_due(
        Scope::Album,
        Scope::Album.current_version(),
        chrono::Utc::now(),
    );
    crate::enrichment::schedule_background_pass(&ui.core);
    ui.core.refresh_job_progress();
    queued
}

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
