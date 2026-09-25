use crate::events::{AppEvent, EventHub};
use crate::library::Track;
use gst::prelude::*;
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::{Rc, Weak};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// PulseAudio (and PipeWire's pulse server behind it) wedges a stream for good
/// when flushing seeks reach it faster than it can cork and uncork: the
/// pipeline keeps reporting PLAYING while the position never moves again, and
/// neither pausing nor another seek brings it back. A drag used to seek on
/// every motion event, which on a 165 Hz display is every six milliseconds —
/// so seeks are now spaced at least this far apart and never overlap one that
/// is still settling.
const SEEK_SPACING: Duration = Duration::from_millis(70);
/// A flushing seek that has not prerolled by now is presumed lost, so a newer
/// target is never stranded behind it.
const SEEK_SETTLE_TIMEOUT: Duration = Duration::from_millis(1500);
/// How soon a seek the pipeline refused (still prerolling a fresh track) is
/// offered again.
const SEEK_RETRY: Duration = Duration::from_millis(100);
/// How far short of the end a seek may land, so a scrub released at 100% plays
/// the last moment out instead of slamming end-of-stream mid-gesture.
pub const END_GUARD: f64 = 0.25;
/// How long a pipeline that claims to be playing may sit on one position before
/// it is reopened where it stopped.
const STALL_THRESHOLD: Duration = Duration::from_millis(2500);
/// Reopens attempted in a row before the watchdog stands down until playback
/// moves again on its own, so slow storage never turns into a reopen loop.
const STALL_RECOVERIES: u32 = 2;
/// Position changes smaller than this are clock noise, not progress.
const STALL_EPSILON: f64 = 0.02;

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

    pub fn id(self) -> &'static str {
        match self {
            RepeatMode::Off => "off",
            RepeatMode::All => "all",
            RepeatMode::One => "one",
        }
    }

    pub fn from_id(id: &str) -> Self {
        match id {
            "all" => RepeatMode::All,
            "one" => RepeatMode::One,
            _ => RepeatMode::Off,
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
    station_seed: Option<String>,
    history_weights: std::collections::HashMap<String, f64>,
    /// Set while a pointer holds the scrubber: the gapless hand-off is not
    /// queued then, because nobody knows yet where the listener will let go.
    scrubbing: bool,
    /// The playing item has already raised `about-to-finish`. playbin3 raises
    /// it once per item and never again after a seek, and a seek issued once
    /// the next track is queued can jump straight into it — so an item in this
    /// state is reopened rather than seeked.
    drained: bool,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum SeekKind {
    /// Chasing a pointer that is still moving: the nearest keyframe will do.
    Scrub,
    /// Where the listener let go, or asked to be: sample-accurate.
    Exact,
}

#[derive(Clone, Copy)]
struct PendingSeek {
    target: f64,
    kind: SeekKind,
    since: Instant,
}

/// Serializes flushing seeks through the pipeline: at most one settling at a
/// time, spaced by `SEEK_SPACING`, and the newest target always wins.
#[derive(Default)]
struct SeekQueue {
    /// The target of the seek (or reopen preroll) the pipeline is still
    /// working through, until ASYNC_DONE says it landed.
    settling: Option<(f64, Instant)>,
    waiting: Option<PendingSeek>,
    last_issued: Option<Instant>,
    /// The play state a reopen restores once its seek has gone out.
    resume: Option<bool>,
    timer: Option<glib::SourceId>,
}

/// Keeps a seek inside the track, stopping `END_GUARD` short of the end. An
/// unknown duration only floors the target at zero.
pub fn clamp_seek(seconds: f64, duration: f64) -> f64 {
    let seconds = if seconds.is_finite() { seconds } else { 0.0 };
    if duration > 0.0 {
        seconds.clamp(0.0, (duration - END_GUARD).max(0.0))
    } else {
        seconds.max(0.0)
    }
}

pub struct QueueSnapshot {
    pub queue: Vec<Track>,
    pub current: usize,
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
    bus_watch: RefCell<Option<gst::bus::BusWatchGuard>>,
    weak_self: Weak<Player>,
    seeks: RefCell<SeekQueue>,
    /// The last position the stall watchdog saw move, and when.
    progress: Cell<Option<(f64, Instant)>>,
    stall_recoveries: Cell<u32>,
    /// Playback was paused because the audio server asked (a call, another
    /// app taking the device), so its all-clear may resume it.
    server_paused: Cell<bool>,
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
            station_seed: None,
            history_weights: std::collections::HashMap::new(),
            scrubbing: false,
            drained: false,
        }));

        {
            let shared = Arc::clone(&shared);
            playbin.connect("about-to-finish", false, move |args| {
                let Some(playbin) = args.first().and_then(|v| v.get::<gst::Element>().ok()) else {
                    return None;
                };
                let Ok(mut guard) = shared.lock() else {
                    return None;
                };
                guard.drained = true;
                if guard.scrubbing {
                    return None;
                }
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

        let player = Rc::new_cyclic(|weak_self| Self {
            playbin: playbin.clone(),
            shared,
            playing: Cell::new(false),
            eos_reset: Cell::new(false),
            hub,
            bus_watch: RefCell::new(None),
            weak_self: weak_self.clone(),
            seeks: RefCell::new(SeekQueue::default()),
            progress: Cell::new(None),
            stall_recoveries: Cell::new(0),
            server_paused: Cell::new(false),
        });

        let bus = playbin.bus().expect("playbin has a bus");
        let guard = {
            let player = Rc::clone(&player);
            let playbin_weak = playbin.downgrade();
            bus.add_watch_local(move |_, message| {
                use gst::MessageView;
                let from_pipeline = || {
                    playbin_weak
                        .upgrade()
                        .map(|pb| message.src().map(|src| *src == pb).unwrap_or(false))
                        .unwrap_or(false)
                };
                match message.view() {
                    MessageView::StreamStart(_) => {
                        if from_pipeline() {
                            player.on_stream_start();
                        }
                    }
                    MessageView::AsyncDone(_) => {
                        if from_pipeline() {
                            player.on_async_done();
                        }
                    }
                    MessageView::RequestState(request) => {
                        player.on_request_state(request.requested_state());
                    }
                    MessageView::Eos(_) => player.on_eos(),
                    MessageView::Error(err) => {
                        let gerror = err.error();
                        crate::logger::error(
                            "playback",
                            &format!("pipeline error: {} ({:?})", gerror, err.debug()),
                        );
                        player.report_playback_error(&gerror);
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

    /// Updates the per-track history weights (max(0.05, age/(age+3d)) from
    /// lastPlayed) that bias shuffle away from recently played tracks.
    pub fn set_history_weights(&self, weights: std::collections::HashMap<String, f64>) {
        if let Ok(mut guard) = self.shared.lock() {
            guard.history_weights = weights;
        }
    }

    fn on_stream_start(&self) {
        let advanced = {
            let Ok(mut guard) = self.shared.lock() else {
                return;
            };
            guard.pending_advance.take().map(|track| {
                let previous = guard.queue.get(guard.current).cloned();
                if let Some(index) = resolve_pending_index(&guard, &track) {
                    guard.current = index;
                }
                guard.drained = false;
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
            self.hub.emit(&AppEvent::QueueChanged);
        }
    }

    /// Surfaces a failed pipeline as a toast, with a codec-specific hint for the
    /// common missing-decoder case (AAC/M4A/ALAC need gst-libav, which the base
    /// runtime deps don't pull in).
    fn report_playback_error(&self, error: &glib::Error) {
        let title = self
            .current_track()
            .map(|track| track.title)
            .unwrap_or_else(|| "this track".to_string());
        let message = if error.matches(gst::CoreError::MissingPlugin) {
            format!(
                "Can't play “{title}” — a codec is missing. Install gst-libav (AAC/M4A/ALAC and more) and restart Flaccy."
            )
        } else {
            format!("Can't play “{title}” — {error}")
        };
        self.hub.emit(&AppEvent::Toast(message));
    }

    fn on_eos(&self) {
        if self.is_scrubbing() {
            crate::logger::info("playback", "reached the end mid-scrub; holding until release");
            return;
        }
        if let Some(track) = self.current_track() {
            self.hub.emit(&AppEvent::NaturalEnd(track));
        }
        let next = {
            let Ok(mut guard) = self.shared.lock() else {
                return;
            };
            guard.pending_advance = None;
            gapless_next_index(&guard)
        };
        if let Some(index) = next {
            crate::logger::info("playback", "EOS with queued next; continuing");
            self.jump_to(index);
            return;
        }
        crate::logger::info("playback", "queue exhausted (EOS)");
        self.clear_seeks();
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
        self.play_queue_with_seed(tracks, start, None);
    }

    pub fn play_queue_with_seed(&self, tracks: Vec<Track>, start: usize, seed: Option<String>) {
        if tracks.is_empty() {
            return;
        }
        let track = {
            let Ok(mut guard) = self.shared.lock() else {
                return;
            };
            guard.original = tracks.clone();
            if guard.shuffle {
                let chosen = tracks[start.min(tracks.len() - 1)].clone();
                let rest: Vec<Track> = tracks
                    .iter()
                    .enumerate()
                    .filter(|(i, _)| *i != start.min(tracks.len() - 1))
                    .map(|(_, t)| t.clone())
                    .collect();
                let weights = guard.history_weights.clone();
                let rest = crate::station::weighted_shuffle(rest, |t| {
                    *weights.get(&t.rel_path).unwrap_or(&1.0)
                });
                let mut queue = vec![chosen];
                queue.extend(rest);
                guard.queue = queue;
                guard.current = 0;
            } else {
                guard.queue = tracks;
                guard.current = start.min(guard.queue.len() - 1);
            }
            guard.pending_advance = None;
            guard.station_seed = seed;
            guard.queue[guard.current].clone()
        };
        self.load_and_play(&track);
        self.hub.emit(&AppEvent::TrackChanged(Some(track)));
        self.hub.emit(&AppEvent::QueueChanged);
    }

    fn load_and_play(&self, track: &Track) {
        let uri = {
            let Ok(guard) = self.shared.lock() else {
                return;
            };
            uri_for(&guard.root, track)
        };
        let Some(uri) = uri else {
            crate::logger::error("playback", &format!("no uri for {}", track.rel_path));
            return;
        };
        if let Ok(mut guard) = self.shared.lock() {
            guard.drained = false;
            guard.scrubbing = false;
        }
        self.clear_seeks();
        let _ = self.playbin.set_state(gst::State::Null);
        self.playbin.set_property("uri", &uri);
        let _ = self.playbin.set_state(gst::State::Playing);
        self.hold_seeks_for_preroll(0.0);
        self.playing.set(true);
        self.eos_reset.set(false);
        self.server_paused.set(false);
        self.progress.set(None);
        self.stall_recoveries.set(0);
        self.hub.emit(&AppEvent::PlayingChanged(true));
        crate::logger::info(
            "playback",
            &format!("playing {} — {}", track.title, track.artist),
        );
    }

    pub fn toggle_play_pause(&self) {
        self.server_paused.set(false);
        self.set_playing(!self.playing.get());
    }

    /// Moves the pipeline to the wanted play state, unless a reopen is still
    /// prerolling — then the reopen applies it once its seek has gone out, so
    /// the track never plays from its first second on the way.
    fn set_playing(&self, playing: bool) {
        if self.current_track().is_none() || self.playing.get() == playing {
            return;
        }
        let deferred = match self.seeks.borrow_mut().resume.as_mut() {
            Some(resume) => {
                *resume = playing;
                true
            }
            None => false,
        };
        if !deferred {
            let state = if playing {
                gst::State::Playing
            } else {
                gst::State::Paused
            };
            let _ = self.playbin.set_state(state);
        }
        self.playing.set(playing);
        self.progress.set(None);
        self.hub.emit(&AppEvent::PlayingChanged(playing));
        if playing && self.eos_reset.replace(false) {
            self.hub.emit(&AppEvent::TrackChanged(self.current_track()));
        }
    }

    /// Honors the audio server's cork and uncork requests (a call starting, a
    /// policy pausing media), so the transport shows paused while the stream
    /// is held instead of claiming to play silence.
    fn on_request_state(&self, state: gst::State) {
        match state {
            gst::State::Paused if self.playing.get() => {
                crate::logger::info("playback", "the audio server asked playback to pause");
                self.set_playing(false);
                self.server_paused.set(true);
            }
            gst::State::Playing if self.server_paused.get() && !self.playing.get() => {
                crate::logger::info("playback", "the audio server released playback");
                self.server_paused.set(false);
                self.set_playing(true);
            }
            _ => {}
        }
    }

    pub fn stop(&self) {
        self.clear_seeks();
        let _ = self.playbin.set_state(gst::State::Null);
        self.playing.set(false);
        self.progress.set(None);
        self.hub.emit(&AppEvent::PlayingChanged(false));
    }

    pub fn next(&self) -> bool {
        let target = {
            let Ok(guard) = self.shared.lock() else {
                return false;
            };
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
            let Ok(guard) = self.shared.lock() else {
                return;
            };
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
            let Ok(mut guard) = self.shared.lock() else {
                return;
            };
            if index >= guard.queue.len() {
                return;
            }
            guard.current = index;
            guard.pending_advance = None;
            guard.queue[index].clone()
        };
        self.load_and_play(&track);
        self.hub.emit(&AppEvent::TrackChanged(Some(track)));
        self.hub.emit(&AppEvent::QueueChanged);
    }

    /// Purges deleted tracks from the queue after a library removal. If the
    /// playing track was deleted, playback advances to the next survivor (or
    /// stops when none remain); an already-primed gapless advance into a
    /// deleted file is cancelled.
    pub fn handle_deleted(&self, rel_paths: &std::collections::HashSet<String>) {
        let (removed_any, current_deleted, replacement) = {
            let Ok(mut guard) = self.shared.lock() else {
                return;
            };
            let before = guard.queue.len();
            if before == 0 {
                return;
            }
            let current_rel = guard
                .queue
                .get(guard.current)
                .map(|track| track.rel_path.clone());
            let removed_before_current = guard
                .queue
                .iter()
                .take(guard.current)
                .filter(|track| rel_paths.contains(&track.rel_path))
                .count();
            guard
                .queue
                .retain(|track| !rel_paths.contains(&track.rel_path));
            guard
                .original
                .retain(|track| !rel_paths.contains(&track.rel_path));
            let removed_any = guard.queue.len() != before;
            let current_deleted = current_rel
                .as_ref()
                .is_some_and(|rel| rel_paths.contains(rel));
            guard.current = guard
                .current
                .saturating_sub(removed_before_current)
                .min(guard.queue.len().saturating_sub(1));
            if guard
                .pending_advance
                .as_ref()
                .is_some_and(|track| rel_paths.contains(&track.rel_path))
            {
                guard.pending_advance = None;
            }
            let replacement = if current_deleted && !guard.queue.is_empty() {
                Some(guard.current)
            } else {
                None
            };
            (removed_any, current_deleted, replacement)
        };
        if current_deleted {
            match replacement {
                Some(index) => self.jump_to(index),
                None => {
                    self.stop();
                    self.hub.emit(&AppEvent::TrackChanged(None));
                    self.hub.emit(&AppEvent::QueueChanged);
                }
            }
        } else if removed_any {
            self.hub.emit(&AppEvent::QueueChanged);
        }
    }

    pub fn insert_next(&self, track: Track) {
        let Ok(mut guard) = self.shared.lock() else {
            return;
        };
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
        drop(guard);
        self.hub.emit(&AppEvent::QueueChanged);
    }

    pub fn add_to_queue(&self, track: Track) {
        let Ok(mut guard) = self.shared.lock() else {
            return;
        };
        if guard.queue.is_empty() {
            drop(guard);
            self.play_queue(vec![track], 0);
            return;
        }
        guard.queue.push(track.clone());
        guard.original.push(track);
        drop(guard);
        self.hub.emit(&AppEvent::QueueChanged);
    }

    pub fn toggle_shuffle(&self) {
        let enabled = {
            let Ok(mut guard) = self.shared.lock() else {
                return;
            };
            guard.shuffle = !guard.shuffle;
            if guard.shuffle {
                if !guard.queue.is_empty() {
                    guard.original = guard.queue.clone();
                    let current = guard.queue[guard.current].clone();
                    let rest: Vec<Track> = guard
                        .queue
                        .iter()
                        .enumerate()
                        .filter(|(i, _)| *i != guard.current)
                        .map(|(_, t)| t.clone())
                        .collect();
                    let weights = guard.history_weights.clone();
                    let rest = crate::station::weighted_shuffle(rest, |t| {
                        *weights.get(&t.rel_path).unwrap_or(&1.0)
                    });
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
        self.hub.emit(&AppEvent::QueueChanged);
    }

    pub fn cycle_repeat(&self) {
        let mode = {
            let Ok(mut guard) = self.shared.lock() else {
                return;
            };
            guard.repeat = guard.repeat.cycled();
            guard.repeat
        };
        self.hub.emit(&AppEvent::RepeatChanged(mode));
    }

    pub fn set_repeat(&self, mode: RepeatMode) {
        if let Ok(mut guard) = self.shared.lock() {
            guard.repeat = mode;
        }
        self.hub.emit(&AppEvent::RepeatChanged(mode));
    }

    /// Restores the shuffle flag without reordering anything — used at launch,
    /// before there is a queue to shuffle. `toggle_shuffle` remains the only
    /// path that reshuffles.
    pub fn set_shuffle(&self, enabled: bool) {
        if let Ok(mut guard) = self.shared.lock() {
            guard.shuffle = enabled;
        }
        self.hub.emit(&AppEvent::ShuffleChanged(enabled));
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

    /// A sample-accurate seek, announced as `Seeked` right away: everything
    /// reading the position sees the target from this moment, even while the
    /// seek is still queued behind one that is settling.
    pub fn seek(&self, seconds: f64) {
        let Some(target) = self.seek_target(seconds) else {
            return;
        };
        self.request_seek(target, SeekKind::Exact);
        self.hub.emit(&AppEvent::Seeked(target));
    }

    /// A pointer took hold of the scrubber.
    pub fn begin_scrub(&self) {
        if let Ok(mut guard) = self.shared.lock() {
            guard.scrubbing = true;
        }
    }

    /// Lets the audio chase a scrub that is still moving. Nothing is heard
    /// while paused, so the release is the only seek then.
    pub fn scrub_to(&self, seconds: f64) {
        if !self.playing.get() {
            return;
        }
        if let Some(target) = self.seek_target(seconds) {
            self.request_seek(target, SeekKind::Scrub);
        }
    }

    /// The pointer let go: one exact seek to where it was released.
    pub fn finish_scrub(&self, seconds: f64) {
        self.end_scrub();
        self.seek(seconds);
    }

    /// The track changed under the gesture, so its release must not seek.
    pub fn abandon_scrub(&self) {
        self.end_scrub();
    }

    fn end_scrub(&self) {
        if let Ok(mut guard) = self.shared.lock() {
            guard.scrubbing = false;
        }
    }

    fn is_scrubbing(&self) -> bool {
        self.shared.lock().map(|g| g.scrubbing).unwrap_or(false)
    }

    fn seek_target(&self, seconds: f64) -> Option<f64> {
        let track = self.current_track()?;
        let duration = self
            .pipeline_duration()
            .filter(|duration| *duration > 0.0)
            .unwrap_or(track.duration);
        Some(clamp_seek(seconds, duration))
    }

    /// Queues a seek, or reopens the track at the target when the playing item
    /// has drained: a scrub only needs that once the next track is queued, an
    /// exact seek whenever `about-to-finish` has fired, so the reopened item
    /// raises it again and the hand-off to the next track stays gapless.
    fn request_seek(&self, target: f64, kind: SeekKind) {
        let (drained, queued) = self
            .shared
            .lock()
            .map(|g| (g.drained, g.pending_advance.is_some()))
            .unwrap_or((false, false));
        let spent = match kind {
            SeekKind::Exact => drained,
            SeekKind::Scrub => queued,
        };
        if spent && self.seeks.borrow().resume.is_none() {
            self.reopen_at(target);
            return;
        }
        self.seeks.borrow_mut().waiting = Some(PendingSeek {
            target,
            kind,
            since: Instant::now(),
        });
        self.pump_seeks();
    }

    /// Issues the waiting seek once nothing is settling and the spacing has
    /// passed; otherwise arms the timer that comes back for it.
    fn pump_seeks(&self) {
        let now = Instant::now();
        let seek = {
            let mut queue = self.seeks.borrow_mut();
            if let Some((target, since)) = queue.settling {
                if now.duration_since(since) < SEEK_SETTLE_TIMEOUT {
                    return;
                }
                crate::logger::warn(
                    "playback",
                    &format!("seek to {target:.1}s never settled; moving on"),
                );
                queue.settling = None;
            }
            let Some(seek) = queue.waiting else {
                return;
            };
            let wait = queue
                .last_issued
                .map(|last| SEEK_SPACING.saturating_sub(now.duration_since(last)))
                .unwrap_or(Duration::ZERO);
            if !wait.is_zero() {
                drop(queue);
                self.arm_seek_timer(wait);
                return;
            }
            queue.waiting = None;
            queue.last_issued = Some(now);
            seek
        };
        let flags = match seek.kind {
            SeekKind::Exact => gst::SeekFlags::FLUSH | gst::SeekFlags::ACCURATE,
            SeekKind::Scrub => {
                gst::SeekFlags::FLUSH | gst::SeekFlags::KEY_UNIT | gst::SeekFlags::SNAP_NEAREST
            }
        };
        let position = gst::ClockTime::from_nseconds((seek.target * 1_000_000_000.0) as u64);
        if self.playbin.seek_simple(flags, position).is_ok() {
            self.seeks.borrow_mut().settling = Some((seek.target, now));
            self.arm_seek_timer(SEEK_SETTLE_TIMEOUT);
        } else if now.duration_since(seek.since) < SEEK_SETTLE_TIMEOUT {
            self.seeks.borrow_mut().waiting.get_or_insert(seek);
            self.arm_seek_timer(SEEK_RETRY);
            return;
        } else {
            crate::logger::warn(
                "playback",
                &format!("the pipeline refused a seek to {:.1}s", seek.target),
            );
        }
        let resume = self.seeks.borrow_mut().resume.take();
        if resume == Some(true) {
            let _ = self.playbin.set_state(gst::State::Playing);
        }
        self.progress.set(None);
    }

    fn arm_seek_timer(&self, after: Duration) {
        let mut queue = self.seeks.borrow_mut();
        if let Some(timer) = queue.timer.take() {
            timer.remove();
        }
        let weak = self.weak_self.clone();
        queue.timer = Some(glib::timeout_add_local_once(after, move || {
            if let Some(player) = weak.upgrade() {
                player.seeks.borrow_mut().timer = None;
                player.pump_seeks();
            }
        }));
    }

    fn clear_seeks(&self) {
        let timer = std::mem::take(&mut *self.seeks.borrow_mut()).timer;
        if let Some(timer) = timer {
            timer.remove();
        }
    }

    /// A pipeline that is still prerolling refuses seeks, so anything asked
    /// for meanwhile waits for its ASYNC_DONE like it would behind a seek.
    fn hold_seeks_for_preroll(&self, position: f64) {
        self.seeks.borrow_mut().settling = Some((position, Instant::now()));
        self.arm_seek_timer(SEEK_SETTLE_TIMEOUT);
    }

    fn on_async_done(&self) {
        let timer = {
            let mut queue = self.seeks.borrow_mut();
            if queue.settling.take().is_none() {
                return;
            }
            queue.timer.take()
        };
        if let Some(timer) = timer {
            timer.remove();
        }
        self.progress.set(None);
        self.pump_seeks();
    }

    /// Reloads the current track and lands it at `target` without a note of
    /// its opening playing on the way: prerolled paused, seeked, then resumed
    /// if it was playing. Also what a wedged audio stream is recovered with.
    fn reopen_at(&self, target: f64) {
        let Some(track) = self.current_track() else {
            return;
        };
        let uri = {
            let Ok(mut guard) = self.shared.lock() else {
                return;
            };
            guard.pending_advance = None;
            guard.drained = false;
            uri_for(&guard.root, &track)
        };
        let Some(uri) = uri else {
            return;
        };
        let resume = self.playing.get();
        self.clear_seeks();
        let _ = self.playbin.set_state(gst::State::Null);
        self.playbin.set_property("uri", &uri);
        let _ = self.playbin.set_state(gst::State::Paused);
        {
            let mut queue = self.seeks.borrow_mut();
            queue.waiting = Some(PendingSeek {
                target,
                kind: SeekKind::Exact,
                since: Instant::now(),
            });
            queue.resume = Some(resume);
        }
        self.hold_seeks_for_preroll(target);
        self.progress.set(None);
        crate::logger::info(
            "playback",
            &format!("reopened {} at {target:.1}s", track.title),
        );
    }

    /// The stall watchdog, run on every playback tick. A pipeline that says it
    /// is playing but has not moved for `STALL_THRESHOLD` is reopened where it
    /// stopped — the only thing that revives a wedged audio stream.
    pub fn check_progress(&self) {
        if !self.playing.get() || self.seek_in_progress().is_some() || self.is_scrubbing() {
            self.progress.set(None);
            return;
        }
        let (_, current, pending) = self.playbin.state(gst::ClockTime::ZERO);
        if current != gst::State::Playing || pending != gst::State::VoidPending {
            self.progress.set(None);
            return;
        }
        let Some(position) = self.pipeline_position() else {
            return;
        };
        let now = Instant::now();
        match self.progress.get() {
            Some((last, _)) if (position - last).abs() > STALL_EPSILON => {
                self.stall_recoveries.set(0);
                self.progress.set(Some((position, now)));
            }
            Some((_, since)) => {
                if now.duration_since(since) >= STALL_THRESHOLD {
                    self.recover_from_stall(position);
                }
            }
            None => self.progress.set(Some((position, now))),
        }
    }

    fn recover_from_stall(&self, position: f64) {
        self.progress.set(None);
        let attempt = self.stall_recoveries.get() + 1;
        self.stall_recoveries.set(attempt);
        if attempt > STALL_RECOVERIES {
            if attempt == STALL_RECOVERIES + 1 {
                crate::logger::error(
                    "playback",
                    &format!(
                        "playback is still stuck at {position:.1}s after {STALL_RECOVERIES} reopens; leaving it be"
                    ),
                );
            }
            return;
        }
        crate::logger::warn(
            "playback",
            &format!("playback stalled at {position:.1}s; reopening the stream (attempt {attempt})"),
        );
        self.reopen_at(position);
    }

    pub fn set_volume(&self, volume: f64) {
        self.playbin.set_property("volume", volume.clamp(0.0, 1.0));
    }

    /// Where playback is, or is about to be: while a seek is queued or still
    /// settling this is its target, so the transport, lyrics and MPRIS never
    /// flick back to where the pipeline was before it lands.
    pub fn position(&self) -> Option<f64> {
        self.seek_in_progress()
            .or_else(|| self.pipeline_position())
    }

    fn seek_in_progress(&self) -> Option<f64> {
        let queue = self.seeks.try_borrow().ok()?;
        queue
            .waiting
            .map(|seek| seek.target)
            .or(queue.settling.map(|(target, _)| target))
    }

    fn pipeline_position(&self) -> Option<f64> {
        self.playbin
            .query_position::<gst::ClockTime>()
            .map(|t| t.nseconds() as f64 / 1_000_000_000.0)
    }

    pub fn duration(&self) -> Option<f64> {
        self.pipeline_duration()
    }

    fn pipeline_duration(&self) -> Option<f64> {
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
        self.shared
            .lock()
            .map(|g| !g.queue.is_empty())
            .unwrap_or(false)
    }

    pub fn queue_snapshot(&self) -> QueueSnapshot {
        self.shared
            .lock()
            .map(|g| QueueSnapshot {
                queue: g.queue.clone(),
                current: g.current,
            })
            .unwrap_or(QueueSnapshot {
                queue: Vec::new(),
                current: 0,
            })
    }

    pub fn station_seed(&self) -> Option<String> {
        self.shared.lock().ok().and_then(|g| g.station_seed.clone())
    }

    /// Removes an upcoming or history queue entry (never the current track),
    /// keeping the current index pointing at the same track.
    pub fn remove_at(&self, index: usize) {
        {
            let Ok(mut guard) = self.shared.lock() else {
                return;
            };
            if index >= guard.queue.len() || index == guard.current {
                return;
            }
            let removed = guard.queue.remove(index);
            if let Some(pos) = guard
                .original
                .iter()
                .position(|t| t.rel_path == removed.rel_path)
            {
                guard.original.remove(pos);
            }
            if index < guard.current {
                guard.current -= 1;
            }
        }
        self.hub.emit(&AppEvent::QueueChanged);
    }

    /// Moves an up-next entry (index > current) to another up-next slot.
    pub fn move_queue_entry(&self, from: usize, to: usize) {
        {
            let Ok(mut guard) = self.shared.lock() else {
                return;
            };
            let len = guard.queue.len();
            if from >= len || to >= len || from <= guard.current || to <= guard.current {
                return;
            }
            let moved = guard.queue.remove(from);
            guard.queue.insert(to, moved);
        }
        self.hub.emit(&AppEvent::QueueChanged);
    }

    pub fn clear_up_next(&self) {
        {
            let Ok(mut guard) = self.shared.lock() else {
                return;
            };
            let keep = guard.current + 1;
            if keep >= guard.queue.len() {
                return;
            }
            let dropped: Vec<String> = guard.queue[keep..]
                .iter()
                .map(|t| t.rel_path.clone())
                .collect();
            guard.queue.truncate(keep);
            guard.original.retain(|t| !dropped.contains(&t.rel_path));
        }
        self.hub.emit(&AppEvent::QueueChanged);
    }

    /// Appends a continuation batch to the tail of the queue (autoplay /
    /// station continuation), mirroring into the original order.
    pub fn append_tracks(&self, tracks: Vec<Track>) {
        if tracks.is_empty() {
            return;
        }
        {
            let Ok(mut guard) = self.shared.lock() else {
                return;
            };
            for track in tracks {
                guard.queue.push(track.clone());
                guard.original.push(track);
            }
        }
        self.hub.emit(&AppEvent::QueueChanged);
    }

    pub fn current_index_and_len(&self) -> (usize, usize) {
        self.shared
            .lock()
            .map(|g| (g.current, g.queue.len()))
            .unwrap_or((0, 0))
    }

    pub fn gst_state_is_playing(&self) -> bool {
        let (_, state, _) = self.playbin.state(gst::ClockTime::from_mseconds(50));
        state == gst::State::Playing
    }
}

#[cfg(test)]
mod tests {
    use super::{clamp_seek, END_GUARD};

    #[test]
    fn a_seek_past_the_end_stops_short_of_it() {
        assert_eq!(clamp_seek(500.0, 200.0), 200.0 - END_GUARD);
        assert_eq!(clamp_seek(200.0, 200.0), 200.0 - END_GUARD);
    }

    #[test]
    fn a_seek_inside_the_track_is_left_alone() {
        assert_eq!(clamp_seek(61.5, 200.0), 61.5);
    }

    #[test]
    fn a_seek_before_the_start_lands_on_it() {
        assert_eq!(clamp_seek(-12.0, 200.0), 0.0);
        assert_eq!(clamp_seek(f64::NAN, 200.0), 0.0);
    }

    #[test]
    fn an_unknown_length_only_floors_the_target() {
        assert_eq!(clamp_seek(4321.0, 0.0), 4321.0);
        assert_eq!(clamp_seek(-1.0, 0.0), 0.0);
    }

    #[test]
    fn a_track_shorter_than_the_guard_seeks_to_its_start() {
        assert_eq!(clamp_seek(0.2, 0.1), 0.0);
    }
}
