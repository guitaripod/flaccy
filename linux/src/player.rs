use crate::events::{AppEvent, EventHub};
use crate::library::Track;
use gst::prelude::*;
use gtk::glib;
use rand::seq::SliceRandom;
use std::cell::Cell;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::{Arc, Mutex};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum RepeatMode {
    Off,
    All,
    One,
}

impl RepeatMode {
    pub fn cycled(self) -> Self {
        match self {
            RepeatMode::Off => RepeatMode::All,
            RepeatMode::All => RepeatMode::One,
            RepeatMode::One => RepeatMode::Off,
        }
    }
}

struct Shared {
    queue: Vec<Track>,
    original: Vec<Track>,
    current: usize,
    repeat: RepeatMode,
    shuffle: bool,
    pending_advance: Option<Track>,
    root: PathBuf,
}

/// Resolves the queue index of a gapless-committed track after possible queue
/// mutations, searching forward from the current position and wrapping so
/// duplicates resolve to the nearest upcoming occurrence.
fn resolve_pending_index(shared: &Shared, track: &Track) -> Option<usize> {
    let len = shared.queue.len();
    if len == 0 {
        return None;
    }
    let start = (shared.current + 1) % len;
    (0..len)
        .map(|offset| (start + offset) % len)
        .find(|&idx| shared.queue[idx].rel_path == track.rel_path)
}

pub struct Player {
    playbin: gst::Element,
    shared: Arc<Mutex<Shared>>,
    playing: Cell<bool>,
    eos_reset: Cell<bool>,
    hub: Rc<EventHub>,
    bus_watch: std::cell::RefCell<Option<gst::bus::BusWatchGuard>>,
}

fn uri_for(root: &Path, track: &Track) -> Option<String> {
    let path = track.abs_path(root);
    glib::filename_to_uri(&path, None::<&str>)
        .map(|uri| uri.to_string())
        .ok()
}

fn gapless_next_index(shared: &Shared) -> Option<usize> {
    if shared.queue.is_empty() {
        return None;
    }
    match shared.repeat {
        RepeatMode::One => Some(shared.current),
        _ => {
            let next = shared.current + 1;
            if next < shared.queue.len() {
                Some(next)
            } else if shared.repeat == RepeatMode::All {
                Some(0)
            } else {
                None
            }
        }
    }
}

impl Player {
    pub fn new(hub: Rc<EventHub>, root: PathBuf) -> Rc<Self> {
        let playbin = gst::ElementFactory::make("playbin3")
            .build()
            .expect("playbin3 must be available");
        playbin.set_property_from_str("flags", "audio+soft-volume");

        let shared = Arc::new(Mutex::new(Shared {
            queue: Vec::new(),
            original: Vec::new(),
            current: 0,
            repeat: RepeatMode::Off,
            shuffle: false,
            pending_advance: None,
            root,
        }));

        {
            let shared = Arc::clone(&shared);
            playbin.connect("about-to-finish", false, move |args| {
                let Some(playbin) = args.first().and_then(|v| v.get::<gst::Element>().ok()) else {
                    return None;
                };
                let Ok(mut guard) = shared.lock() else { return None };
                if let Some(next) = gapless_next_index(&guard) {
                    let track = guard.queue[next].clone();
                    if let Some(uri) = uri_for(&guard.root, &track) {
                        playbin.set_property("uri", &uri);
                        guard.pending_advance = Some(track);
                    }
                }
                None
            });
        }

        let player = Rc::new(Self {
            playbin: playbin.clone(),
            shared,
            playing: Cell::new(false),
            eos_reset: Cell::new(false),
            hub,
            bus_watch: std::cell::RefCell::new(None),
        });

        let bus = playbin.bus().expect("playbin has a bus");
        let guard = {
            let player = Rc::clone(&player);
            let playbin_weak = playbin.downgrade();
            bus.add_watch_local(move |_, message| {
                use gst::MessageView;
                match message.view() {
                    MessageView::StreamStart(_) => {
                        let is_pipeline = playbin_weak
                            .upgrade()
                            .map(|pb| {
                                message
                                    .src()
                                    .map(|src| *src == pb)
                                    .unwrap_or(false)
                            })
                            .unwrap_or(false);
                        if is_pipeline {
                            player.on_stream_start();
                        }
                    }
                    MessageView::Eos(_) => player.on_eos(),
                    MessageView::Error(err) => {
                        crate::logger::error(
                            "playback",
                            &format!("pipeline error: {} ({:?})", err.error(), err.debug()),
                        );
                        player.stop();
                    }
                    _ => {}
                }
                glib::ControlFlow::Continue
            })
            .expect("bus watch")
        };
        *player.bus_watch.borrow_mut() = Some(guard);

        player
    }

    pub fn set_root(&self, root: PathBuf) {
        if let Ok(mut guard) = self.shared.lock() {
            guard.root = root;
        }
    }

    fn on_stream_start(&self) {
        let advanced = {
            let Ok(mut guard) = self.shared.lock() else { return };
            guard.pending_advance.take().map(|track| {
                let previous = guard.queue.get(guard.current).cloned();
                if let Some(index) = resolve_pending_index(&guard, &track) {
                    guard.current = index;
                }
                (previous, Some(track))
            })
        };
        if let Some((previous, current)) = advanced {
            if let Some(previous) = previous {
                self.hub.emit(&AppEvent::NaturalEnd(previous));
            }
            crate::logger::info(
                "playback",
                &format!(
                    "gapless advance to {}",
                    current.as_ref().map(|t| t.title.as_str()).unwrap_or("?")
                ),
            );
            self.hub.emit(&AppEvent::TrackChanged(current));
        }
    }

    fn on_eos(&self) {
        if let Some(track) = self.current_track() {
            self.hub.emit(&AppEvent::NaturalEnd(track));
        }
        let next = {
            let Ok(mut guard) = self.shared.lock() else { return };
            guard.pending_advance = None;
            gapless_next_index(&guard)
        };
        if let Some(index) = next {
            crate::logger::info("playback", "EOS with queued next; continuing");
            self.jump_to(index);
            return;
        }
        crate::logger::info("playback", "queue exhausted (EOS)");
        let _ = self.playbin.set_state(gst::State::Paused);
        let _ = self.playbin.seek_simple(
            gst::SeekFlags::FLUSH | gst::SeekFlags::KEY_UNIT,
            gst::ClockTime::ZERO,
        );
        self.playing.set(false);
        self.eos_reset.set(true);
        self.hub.emit(&AppEvent::Seeked(0.0));
        self.hub.emit(&AppEvent::PlayingChanged(false));
    }

    pub fn play_queue(&self, tracks: Vec<Track>, start: usize) {
        if tracks.is_empty() {
            return;
        }
        let track = {
            let Ok(mut guard) = self.shared.lock() else { return };
            guard.original = tracks.clone();
            if guard.shuffle {
                let chosen = tracks[start.min(tracks.len() - 1)].clone();
                let mut rest: Vec<Track> = tracks
                    .iter()
                    .enumerate()
                    .filter(|(i, _)| *i != start.min(tracks.len() - 1))
                    .map(|(_, t)| t.clone())
                    .collect();
                rest.shuffle(&mut rand::rng());
                let mut queue = vec![chosen];
                queue.extend(rest);
                guard.queue = queue;
                guard.current = 0;
            } else {
                guard.queue = tracks;
                guard.current = start.min(guard.queue.len() - 1);
            }
            guard.pending_advance = None;
            guard.queue[guard.current].clone()
        };
        self.load_and_play(&track);
        self.hub.emit(&AppEvent::TrackChanged(Some(track)));
    }

    fn load_and_play(&self, track: &Track) {
        let uri = {
            let Ok(guard) = self.shared.lock() else { return };
            uri_for(&guard.root, track)
        };
        let Some(uri) = uri else {
            crate::logger::error("playback", &format!("no uri for {}", track.rel_path));
            return;
        };
        let _ = self.playbin.set_state(gst::State::Null);
        self.playbin.set_property("uri", &uri);
        let _ = self.playbin.set_state(gst::State::Playing);
        self.playing.set(true);
        self.eos_reset.set(false);
        self.hub.emit(&AppEvent::PlayingChanged(true));
        crate::logger::info(
            "playback",
            &format!("playing {} — {}", track.title, track.artist),
        );
    }

    pub fn toggle_play_pause(&self) {
        let has_track = self.current_track().is_some();
        if !has_track {
            return;
        }
        if self.playing.get() {
            let _ = self.playbin.set_state(gst::State::Paused);
            self.playing.set(false);
            self.hub.emit(&AppEvent::PlayingChanged(false));
        } else {
            let _ = self.playbin.set_state(gst::State::Playing);
            self.playing.set(true);
            self.hub.emit(&AppEvent::PlayingChanged(true));
            if self.eos_reset.replace(false) {
                self.hub.emit(&AppEvent::TrackChanged(self.current_track()));
            }
        }
    }

    pub fn stop(&self) {
        let _ = self.playbin.set_state(gst::State::Null);
        self.playing.set(false);
        self.hub.emit(&AppEvent::PlayingChanged(false));
    }

    pub fn next(&self) -> bool {
        let target = {
            let Ok(guard) = self.shared.lock() else { return false };
            if guard.queue.is_empty() {
                None
            } else {
                let next = guard.current + 1;
                if next < guard.queue.len() {
                    Some(next)
                } else if guard.repeat == RepeatMode::All {
                    Some(0)
                } else {
                    None
                }
            }
        };
        match target {
            Some(index) => {
                self.jump_to(index);
                true
            }
            None => false,
        }
    }

    pub fn previous(&self) {
        if self.position().unwrap_or(0.0) > 3.0 {
            self.seek(0.0);
            return;
        }
        let target = {
            let Ok(guard) = self.shared.lock() else { return };
            if guard.queue.is_empty() {
                None
            } else if guard.current > 0 {
                Some(guard.current - 1)
            } else if guard.repeat == RepeatMode::All {
                Some(guard.queue.len() - 1)
            } else {
                None
            }
        };
        match target {
            Some(index) => self.jump_to(index),
            None => {
                self.seek(0.0);
            }
        }
    }

    pub fn jump_to(&self, index: usize) {
        let track = {
            let Ok(mut guard) = self.shared.lock() else { return };
            if index >= guard.queue.len() {
                return;
            }
            guard.current = index;
            guard.pending_advance = None;
            guard.queue[index].clone()
        };
        self.load_and_play(&track);
        self.hub.emit(&AppEvent::TrackChanged(Some(track)));
    }

    pub fn insert_next(&self, track: Track) {
        let Ok(mut guard) = self.shared.lock() else { return };
        if guard.queue.is_empty() {
            drop(guard);
            self.play_queue(vec![track], 0);
            return;
        }
        let insert_at = (guard.current + 1).min(guard.queue.len());
        guard.queue.insert(insert_at, track.clone());
        let current_rel = guard.queue[guard.current].rel_path.clone();
        let original_pos = guard
            .original
            .iter()
            .position(|t| t.rel_path == current_rel)
            .map(|p| p + 1)
            .unwrap_or(guard.original.len());
        guard.original.insert(original_pos, track);
    }

    pub fn add_to_queue(&self, track: Track) {
        let Ok(mut guard) = self.shared.lock() else { return };
        if guard.queue.is_empty() {
            drop(guard);
            self.play_queue(vec![track], 0);
            return;
        }
        guard.queue.push(track.clone());
        guard.original.push(track);
    }

    pub fn toggle_shuffle(&self) {
        let enabled = {
            let Ok(mut guard) = self.shared.lock() else { return };
            guard.shuffle = !guard.shuffle;
            if guard.shuffle {
                if !guard.queue.is_empty() {
                    guard.original = guard.queue.clone();
                    let current = guard.queue[guard.current].clone();
                    let mut rest: Vec<Track> = guard
                        .queue
                        .iter()
                        .enumerate()
                        .filter(|(i, _)| *i != guard.current)
                        .map(|(_, t)| t.clone())
                        .collect();
                    rest.shuffle(&mut rand::rng());
                    let mut queue = vec![current];
                    queue.extend(rest);
                    guard.queue = queue;
                    guard.current = 0;
                }
            } else if !guard.original.is_empty() {
                let current_rel = guard
                    .queue
                    .get(guard.current)
                    .map(|t| t.rel_path.clone())
                    .unwrap_or_default();
                guard.queue = guard.original.clone();
                guard.current = guard
                    .queue
                    .iter()
                    .position(|t| t.rel_path == current_rel)
                    .unwrap_or(0);
            }
            guard.shuffle
        };
        self.hub.emit(&AppEvent::ShuffleChanged(enabled));
    }

    pub fn cycle_repeat(&self) {
        let mode = {
            let Ok(mut guard) = self.shared.lock() else { return };
            guard.repeat = guard.repeat.cycled();
            guard.repeat
        };
        self.hub.emit(&AppEvent::RepeatChanged(mode));
    }

    #[allow(dead_code)]
    pub fn repeat_mode(&self) -> RepeatMode {
        self.shared
            .lock()
            .map(|g| g.repeat)
            .unwrap_or(RepeatMode::Off)
    }

    pub fn shuffle_enabled(&self) -> bool {
        self.shared.lock().map(|g| g.shuffle).unwrap_or(false)
    }

    pub fn seek(&self, seconds: f64) {
        let clamped = seconds.max(0.0);
        let _ = self.playbin.seek_simple(
            gst::SeekFlags::FLUSH | gst::SeekFlags::ACCURATE,
            gst::ClockTime::from_nseconds((clamped * 1_000_000_000.0) as u64),
        );
        self.hub.emit(&AppEvent::Seeked(clamped));
    }

    pub fn set_volume(&self, volume: f64) {
        self.playbin
            .set_property("volume", volume.clamp(0.0, 1.0));
    }

    pub fn position(&self) -> Option<f64> {
        self.playbin
            .query_position::<gst::ClockTime>()
            .map(|t| t.nseconds() as f64 / 1_000_000_000.0)
    }

    pub fn duration(&self) -> Option<f64> {
        self.playbin
            .query_duration::<gst::ClockTime>()
            .map(|t| t.nseconds() as f64 / 1_000_000_000.0)
    }

    pub fn is_playing(&self) -> bool {
        self.playing.get()
    }

    pub fn current_track(&self) -> Option<Track> {
        self.shared
            .lock()
            .ok()
            .and_then(|g| g.queue.get(g.current).cloned())
    }

    #[allow(dead_code)]
    pub fn has_next(&self) -> bool {
        self.shared
            .lock()
            .map(|g| {
                !g.queue.is_empty()
                    && (g.current + 1 < g.queue.len() || g.repeat != RepeatMode::Off)
            })
            .unwrap_or(false)
    }

    #[allow(dead_code)]
    pub fn has_previous(&self) -> bool {
        self.shared.lock().map(|g| !g.queue.is_empty()).unwrap_or(false)
    }

    pub fn gst_state_is_playing(&self) -> bool {
        let (_, state, _) = self.playbin.state(gst::ClockTime::from_mseconds(50));
        state == gst::State::Playing
    }
}
