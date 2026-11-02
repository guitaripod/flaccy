//! Lyrics and music videos prepared before they are asked for. This module is
//! the coordinator on the main thread: it notices that the queue, the library
//! or a setting changed, waits for the dust to settle, and hands each lane the
//! queue as it stands. The planning is `flaccy_shared::precache`; the lanes
//! are `lyrics_lane` and `musicvideo`'s video lane, which fetch at a pace the
//! servers accept and rest when they are told to.

pub mod candidates;
pub mod governor;
mod lyrics_lane;
pub mod status;

pub use governor::LRCLIB;

use crate::app::AppCore;
use crate::events::AppEvent;
use gtk::gio::prelude::NetworkMonitorExt;
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// How long changes are left to settle before the lanes are told: skipping
/// through a queue should cost one plan, not twenty.
const SETTLE: Duration = Duration::from_millis(1500);

/// Why the lanes should not be fetching right now, or `None` to go ahead.
pub type Blocker = Arc<dyn Fn() -> Option<&'static str> + Send + Sync>;

pub struct PrecacheHandle {
    lyrics: RefCell<Option<async_channel::Sender<Option<lyrics_lane::Intent>>>>,
    queued: Cell<bool>,
    metered: Arc<AtomicBool>,
}

impl PrecacheHandle {
    pub fn new() -> Self {
        Self {
            lyrics: RefCell::new(None),
            queued: Cell::new(false),
            metered: Arc::new(AtomicBool::new(false)),
        }
    }
}

/// What holds the lanes back: no network, or a connection the listener pays
/// by the byte. Preparing ahead is never worth either.
pub fn blocker_reason(available: bool, suspect: bool, metered: bool) -> Option<&'static str> {
    if !available || suspect {
        Some("Waiting for the network")
    } else if metered {
        Some("Paused on a metered connection")
    } else {
        None
    }
}

/// A blocker the lane threads can ask, reading the app's network flags.
pub fn blocker(core: &AppCore) -> Blocker {
    let available = Arc::clone(&core.network_available);
    let suspect = Arc::clone(&core.network_suspect);
    let metered = Arc::clone(&core.precache.metered);
    Arc::new(move || {
        blocker_reason(
            available.load(Ordering::Relaxed),
            suspect.load(Ordering::Relaxed),
            metered.load(Ordering::Relaxed),
        )
    })
}

fn watch_metered(core: &Rc<AppCore>) {
    let monitor = gtk::gio::NetworkMonitor::default();
    core.precache
        .metered
        .store(monitor.is_network_metered(), Ordering::Relaxed);
    let metered = Arc::clone(&core.precache.metered);
    let weak = Rc::downgrade(core);
    monitor.connect_network_metered_notify(move |monitor| {
        metered.store(monitor.is_network_metered(), Ordering::Relaxed);
        if let Some(core) = weak.upgrade() {
            refresh(&core);
        }
    });
}

pub fn start(core: &Rc<AppCore>) {
    watch_metered(core);
    let tx = lyrics_lane::spawn(core.db_path.clone(), core.music_root(), blocker(core));
    *core.precache.lyrics.borrow_mut() = Some(tx);

    let weak = Rc::downgrade(core);
    core.hub.subscribe(move |event| {
        let Some(core) = weak.upgrade() else {
            return false;
        };
        if matches!(
            event,
            AppEvent::TrackChanged(_)
                | AppEvent::QueueChanged
                | AppEvent::LibraryReloaded
                | AppEvent::ScanFinished { .. }
        ) {
            refresh(&core);
        }
        true
    });
}

/// Asks for a new plan once changes have settled.
pub fn refresh(core: &Rc<AppCore>) {
    if core.precache.queued.replace(true) {
        return;
    }
    let weak = Rc::downgrade(core);
    glib::timeout_add_local_once(SETTLE, move || {
        let Some(core) = weak.upgrade() else {
            return;
        };
        core.precache.queued.set(false);
        push(&core);
    });
}

fn push(core: &Rc<AppCore>) {
    let snapshot = core.player.queue_snapshot();
    let queue: Vec<_> = snapshot
        .queue
        .iter()
        .skip(snapshot.current)
        .take(candidates::QUEUE_WINDOW)
        .cloned()
        .collect();
    let whole_library = core.config.borrow().lyrics_whole_library;
    if let Some(tx) = core.precache.lyrics.borrow().as_ref() {
        let _ = tx.send_blocking(Some(lyrics_lane::Intent {
            queue: queue.clone(),
            whole_library,
        }));
    }
    crate::musicvideo::warm(core, queue);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_network_outranks_a_metered_one_and_both_hold_the_lanes_back() {
        assert_eq!(blocker_reason(true, false, false), None);
        assert_eq!(blocker_reason(false, false, false), Some("Waiting for the network"));
        assert_eq!(blocker_reason(true, true, false), Some("Waiting for the network"));
        assert_eq!(blocker_reason(true, false, true), Some("Paused on a metered connection"));
        assert_eq!(blocker_reason(false, false, true), Some("Waiting for the network"));
    }
}
